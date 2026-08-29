/*
  This file is the shadow profiler. we create a napi that will track all the objects allocated by JS
  adding a callsite hash, lifespan, and size to the profiler and will be fed into the ML

  This design is the v2. upgraded over the original design motivated by running
  inside a 1GB-constrained container during characterization:

  1.  SLOT RECYCLING: The original design used a fixed pool sized to the TOTAL
      number of allocations expected across an entire run. (e.g., 5 000 000 slots ~= 200-240MB reserved upfront)
      That means memory competes with the very workload being characterized, distorting the memory pressure SAMM is meant to observe.
      In this version, a skit us returned to a free-list the instant its object finalizes, so pool capacity only needs
      to cover the number of objects CONCURRENTLY alive at once.

  2.  BACKGROUND WRITER THREAD: file I/O no longer happens on the main JS thread. The finalizer callback (which MUST run on the
      main thread) does the minimum work possible: copy four numbers into a thread-safe queue and return the slot to the free-list
      A dedicated background thread drains that queue and owns all disk I/O, so a slow flush can never stall request handling.
  
  Neither change alters what is measured (GC-observed lifespan is still GC-observed lifespan). Both changes reduce the profiler's
  OWN contribution to memory and timing distortion, which is the "observer effect contamination" the methodology already commits to avoiding.

  Thread-safety note: track() and the finalizer callback are both guaranteed by N-API to execute on the main JS thread, and never
  concurrently with each other. This means the pool, the free-list  and the in-use table need NO lcking. Only the hand-off queue between
  the main thread and the writer thread needs synchronization.
*/

/*
  HOW IT WORKS:
  1. First, the JS calls this file to watch the object
  2. C++ stores the object details in a pre-allocated memory pool
  3. C++ attaches a Finalizer (a ghost hook) to the object
  4. When V8 destroys the object, the hook fires and calculates how long the object lived
     then hands that data to a Queue. 
  5. A background thread reads from the queue and writes to a csv file on disk, keeping disk I/O off the main Node.js thread
*/

#include <napi.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>


namespace {
  
  /*
    PART 1: Memory Pool
    This is the section where we put all the concurrent objects that we are tracking
  */

  // This struct represents a single tracked JS object
  struct AllocRecord {
    uint64_t call_site_hash = 0; // 64-bit integer instead of a string of the function that called this object
    uint64_t size_bytes = 0; // size of the object in bytes. passed in from JS
    double alloc_time_ms = 0.0; // start time of tracking
  };

  // we only need to store objects that are concurrenctly alive in v8
  // configurable via SHADOW_PROFILER_CAPACITY
  constexpr size_t kDefaultCapacity = 100'000;


  std::vector<AllocRecord> g_pool; // the array of memory where we gonna put the allocRecords
  std::vector<bool> g_in_use; //quick lookup if this slot is occupied
  std::vector<size_t> g_free_list; // stack of available index slots
  size_t g_capacity = 0;

  // this variable stores the exact moment the this file booted up.
  // basically the start of the time
  std::chrono::steady_clock::time_point g_epoch;

  // calculates how many milliseconds have passed since boot
  // it is called when an object is tracked, and again when it dies
  double NowMs(){
    auto elapsed = std::chrono::steady_clock::now() - g_epoch;
    return std::chrono::duration<double, std::milli>(elapsed).count();
  }

  //FNV-1a Hash Algorithm for fast string to integer conversion for call-site IDs
  uint64_t Fnv1aHash(const std::string& input) {
    constexpr uint64_t kOffsetBasis = 1469598103934665603ULL;
    constexpr uint64_t kPrime = 1099511628211ULL;
    uint64_t hash = kOffsetBasis;

    for (unsigned char c: input) {
      hash ^= static_cast<uint64_t>(c);
      hash *= kPrime;
    }
    return hash;
  }

  /*
    Part 2: Thread Hand-Off Queue
    NodeJS is single thread. If JS object dies and profiler immediately tries to write that info into a CSV,
    it will block the event loop. The server would freeze every time a garbage collection happened, making our telemetry inaccurate.

    to solve this, we use the producer-consumer pattern,
    - Producer(the main thread) creates data and pushes it into a queue
    - Consumer(the background thread) pops the data out of the bucket and writes it into the hard drive.
  */

  // The data payload to be pushed into the queue, which then will be written to the file by the background thread
  struct QueuedRecord {
    uint64_t call_site_hash;
    uint64_t size_bytes; 
    double alloc_time_ms;
    double finalize_time_ms; //time that v8 destroyed the object
    bool censored; // if user stops the profiler while the object is still alive, we mark it as true. that means 
    // no data about when it died. 
  };

  // Thread Synchronization Primitives 
  std::mutex g_queue_mutex; // mutex prevents the main thread and writer thread from reading/writing to the queue at the same time
  std::condition_variable g_queue_cv; // to make the background thread only wake up when the data arrives
  std::deque<QueuedRecord> g_write_queue; // The actual queue holding the data

  // Thread State
  std::atomic<bool> g_shutdown_requested{false}; // to make sure bthread also dies when the app is closing
  std::thread g_writer_thread; //the actual thread
  std::atomic<bool> g_writer_running{false}; //keeps track of whether the background thread is runinng

  // Telemetry Stats
  // atomic variances can be read and changed by multiple threads safely without needed a slow mutex lock.
  std::atomic<uint64_t> g_total_tracked{0};
  std::atomic<uint64_t> g_total_written{0};
  std::atomic<uint64_t> g_total_censored{0};

  // This is the Queue where we add objects V8 destroyed.
  void EnqueueRecord(const QueuedRecord& rec) {
    {
      //locks the mutex so no other threads can touch the queue
      std::lock_guard<std::mutex> lock(g_queue_mutex);
      // push the data into the back of the queue
      g_write_queue.push_back(rec);
    }

    //notify the background thread to wake it up and process the data
    g_queue_cv.notify_one();
  }

  /*
    PART 3: Background Writer Thread
    Writing to hard drive is incredibly slow compared to RAM. if we kept the queue locked while writing to the csv
    the main node.js thread will hit the lock and be forced to wait. so we need to put the shared queue into a private
    batch array to unlock the mutex immediately.
  */

  // helper function to check if the file already exist
  // if it's a new file, we write the csv column headers
  void WriteCsvHeaderIfNeeded(const std::string& path) {
    std::ifstream check(path);
    bool exists = check.good() && check.peek() != std::ifstream::traits_type::eof();
    check.close();

    if (!exists){
      std::ofstream out(path, std::ios::out | std::ios::trunc);
      out << "call_site_hash,allocation_size_bytes,allocation_time_ms,finalization_time_ms\n";
    }
  }

  // background thread.
  void WriterThreadMain(std::string path){
    WriteCsvHeaderIfNeeded(path);

    //append mode so we js keep addign to the bottom
    std::ofstream out(path, std::ios::out | std::ios::app);

    // the private queue for storing the data from the actual queue to unlock it immediately
    std::vector<QueuedRecord> batch;
    batch.reserve(1024);

    while (true) {
      {
        //locks the queue
        std::unique_lock<std::mutex> lock (g_queue_mutex);

        //unlocks the mutex and goes to sleep
        g_queue_cv.wait(lock, [] {
          //wake up if there is data to processs
          return !g_write_queue.empty() || g_shutdown_requested.load();
        });
        
        // drain the queue into our local batch
        batch.clear();
        while (!g_write_queue.empty()){
          batch.push_back(g_write_queue.front()); //copy to local batch
          g_write_queue.pop_front(); //remove from the shared queue
        }
        
        // exit the loop only if the queue is empty and shutdown was requested
        if (batch.empty() && g_shutdown_requested.load()){
          break;
        }
      }
      //mutex is released

      //we write the batch to disk
      for (const auto& rec : batch) {
        out << rec.call_site_hash << ',' << rec.size_bytes << ',' << rec.alloc_time_ms << ',';
        if (rec.censored) {
          out << ""; 
          g_total_censored.fetch_add(1, std::memory_order_relaxed);
        } else {
          out << rec.finalize_time_ms;
          g_total_written.fetch_add(1, std::memory_order_relaxed);
          }
        out << '\n';
        }
        out.flush();
    }
    out.flush();
  }

  /*
    Part 4: V8 Finalizer hook
      Finalizer is a special callback function provided by N-API which allows C++ code to 
      attach a hidden hook to a normal JS object. when the V8 GC sweeps that object out of memory. it triggers this C++ function
      at that exact millisecond.
  */

  // This function is executed purely by the V8 GC
  // It receives the Napi environment, and a custom pointer (idx_ptr) that we 
  // attach to the object when we started tracking it.

  void OnObjectFinalized(Napi::Env /*env*/, size_t* idx_ptr) {
	
	//dereference the pointer to get the actual number
	size_t idx = *idx_ptr;
	
	//since the object is dead, we must delete the pointer to prevent memory leaks
	delete idx_ptr;

	//we use the index to look up the object's original data in our memory pool
	const AllocRecord& rec = g_pool[idx];

	// create the object so we can add the data into the queue
	QueuedRecord queued;
	queued.call_site_hash = rec.call_site_hash; // call site
	queued.size_bytes = rec.size_bytes; // payload size
	queued.alloc_time_ms = rec.alloc_time_ms; // payload lifespan start

	queued.finalize_time_ms = NowMs(); // payload lifespan death

	queued.censored = false; //since it wasnt killed by the server shutting down, it's false

	EnqueueRecord(queued); //send to the shared queue

	g_in_use[idx] = false; //recycle the slot

	g_free_list.push_back(idx); //add to the free list


  }
  
  /* 
   * Part 5: JS to C++ Bindings
   * this is basically the translation layer between JS and C++.
  */

  // 1. THE "TRACK" FUNCTION
  // Called from JS as: native.track(obj, callSiteId, sizeBytes)
  Napi::Value Track(const Napi::CallbackInfo& info) {
      Napi::Env env = info.Env(); // The V8 JavaScript environment

      // Type Validation: Ensure JS passed exactly: (Object, String, Number)
      if (info.Length() < 3 || !info[0].IsObject() || !info[1].IsString() || !info[2].IsNumber()) {
          Napi::TypeError::New(env, "track(object, callSiteId: string, sizeBytes: number) expected").ThrowAsJavaScriptException();
          return env.Undefined();
      }

      // Capacity Check
      if (g_free_list.empty()) {
          static std::atomic<bool> warned{false};
          // exchange(true) ensures this warning only prints exactly ONCE to the console
          if (!warned.exchange(true)) {
              fprintf(stderr, "[shadow-profiler] WARNING: no free slots available. Increase SHADOW_PROFILER_CAPACITY.\n");
          }
          return Napi::Boolean::New(env, false); // Tell JS tracking failed
      }

      // Get an index and mark it as occupied
      size_t idx = g_free_list.back();
      g_free_list.pop_back();
      g_in_use[idx] = true;

      // Convert JS types to C++ primitives
      std::string call_site_id = info[1].As<Napi::String>().Utf8Value();
      int64_t size_bytes = info[2].As<Napi::Number>().Int64Value();

      // Store the data in our Memory Pool
      AllocRecord& rec = g_pool[idx];
      rec.call_site_hash = Fnv1aHash(call_site_id);
      rec.size_bytes = static_cast<uint64_t>(size_bytes < 0 ? 0 : size_bytes);
      rec.alloc_time_ms = NowMs();

      g_total_tracked.fetch_add(1, std::memory_order_relaxed);

      // Create a stable C++ pointer to hold our room key. 
      // This is passed into the Finalizer so we know WHICH object just died.
      size_t* idx_ptr = new size_t(idx);

      // ATTACH THE GHOST HOOK! 
      // We tell V8: "When this JS object is garbage collected, run OnObjectFinalized and give it idx_ptr"
      Napi::Object obj = info[0].As<Napi::Object>();
      obj.AddFinalizer(OnObjectFinalized, idx_ptr);

      return Napi::Boolean::New(env, true);
  }

  // 2. THE "START" FUNCTION
  // Called from JS as: native.start(filePath)
  Napi::Value Start(const Napi::CallbackInfo& info) {
      Napi::Env env = info.Env();

      // Prevent starting two background threads by accident
      if (g_writer_running.exchange(true)) {
          return Napi::Boolean::New(env, false); 
      }

      std::string path = info[0].As<Napi::String>().Utf8Value();
      g_shutdown_requested.store(false);
      
      // Launch the background thread! 
      // It will run WriterThreadMain(path) on a separate CPU core.
      g_writer_thread = std::thread(WriterThreadMain, path);

      return Napi::Boolean::New(env, true);
  }

  // 3. THE "STOP" FUNCTION
  // Called from JS as: native.stop()
  Napi::Value Stop(const Napi::CallbackInfo& info) {
      Napi::Env env = info.Env();

      // RIGHT-CENSORED SWEEP
      // The app is shutting down, but many tracked objects are STILL ALIVE in memory.
      // We loop through the entire pool to find occupied rooms.
      for (size_t idx = 0; idx < g_capacity; ++idx) {
          if (g_in_use[idx]) {
              const AllocRecord& rec = g_pool[idx];
              QueuedRecord queued;
              queued.call_site_hash = rec.call_site_hash;
              queued.size_bytes = rec.size_bytes;
              queued.alloc_time_ms = rec.alloc_time_ms;
              queued.finalize_time_ms = -1.0; 
              queued.censored = true; // Mark as "died because of shutdown, not GC"
              
              EnqueueRecord(queued);
              g_in_use[idx] = false;
          }
      }

      // Tell the background thread to finish writing and exit its infinite loop
      g_shutdown_requested.store(true);
      g_queue_cv.notify_all(); // Wake it up!

      // Wait here until the background thread completely finishes its final disk writes
      if (g_writer_thread.joinable()) {
          g_writer_thread.join();
      }
      g_writer_running.store(false);

      // Return the final stats to JS as an object: { written: X, censored: Y }
      Napi::Object result = Napi::Object::New(env);
      result.Set("written", Napi::Number::New(env, static_cast<double>(g_total_written.load())));
      result.Set("censored", Napi::Number::New(env, static_cast<double>(g_total_censored.load())));
      return result;
  }

  // 4. THE "GET STATS" FUNCTION
  // Called from JS to monitor health: native.getStats()
  Napi::Value GetStats(const Napi::CallbackInfo& info) {
      Napi::Env env = info.Env();

      size_t free_count = g_free_list.size();
      size_t in_use_count = g_capacity - free_count;

      Napi::Object result = Napi::Object::New(env);
      result.Set("capacity", Napi::Number::New(env, static_cast<double>(g_capacity)));
      result.Set("inUse", Napi::Number::New(env, static_cast<double>(in_use_count)));
      result.Set("free", Napi::Number::New(env, static_cast<double>(free_count)));
      result.Set("totalTracked", Napi::Number::New(env, static_cast<double>(g_total_tracked.load())));
      result.Set("totalWritten", Napi::Number::New(env, static_cast<double>(g_total_written.load())));
      result.Set("totalCensored", Napi::Number::New(env, static_cast<double>(g_total_censored.load())));
      return result;
  }

  // 5. MODULE INITIALIZATION
  // This runs exactly ONCE when you `require('shadow_profiler')` in Node.js
  Napi::Object Init(Napi::Env env, Napi::Object exports) {
      // Record the exact boot time
      g_epoch = std::chrono::steady_clock::now();

      size_t capacity = kDefaultCapacity; // 100,000
      
      // Read `process.env.SHADOW_PROFILER_CAPACITY` from Node.js
      Napi::Object process_env = env.Global().Get("process").As<Napi::Object>().Get("env").As<Napi::Object>();
      Napi::Value capacity_override = process_env.Get("SHADOW_PROFILER_CAPACITY");
      if (capacity_override.IsString()) {
          std::string s = capacity_override.As<Napi::String>().Utf8Value();
          if (!s.empty()) capacity = static_cast<size_t>(std::stoull(s)); // Convert String to Number
      }

      // Allocate the massive Memory Pool arrays based on capacity
      g_capacity = capacity;
      g_pool.resize(g_capacity);
      g_in_use.assign(g_capacity, false);

      // Pre-fill the Free List with all room numbers (from 99,999 down to 0)
      g_free_list.clear();
      g_free_list.reserve(g_capacity);
      for (size_t i = g_capacity; i-- > 0;) {
          g_free_list.push_back(i);
      }

      // Map the C++ functions to JavaScript function names
      exports.Set("track", Napi::Function::New(env, Track));
      exports.Set("start", Napi::Function::New(env, Start));
      exports.Set("stop", Napi::Function::New(env, Stop));
      exports.Set("getStats", Napi::Function::New(env, GetStats));

      return exports;
  }

}  // namespace

NODE_API_MODULE(shadow_profiler, Init)
