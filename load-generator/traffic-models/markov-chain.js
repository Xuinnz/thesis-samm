// uses the markov matrix from step 2.1 to know what would be the next state
// between idle, ramp, burst, cooldown

/**
 * We dont hardcode RPS because Azure's raw numbers are astronomical. Instead, this function
 * normalizes the trace, Burst has the highest (1.0) and if Idle is roughly 71% of Burst, we preserve that ratio
 * 
 * WE then map that ratio onto a scale of the docker container can survive. (e.g., 5 to 200 RPS)
 * This perfectly retains the behavioral shape of Microsoft Azure traffic while fitting inside a 1GB environment
 * 
 * We also add a seed to make the random walk generates the exact same traffic sequence for both baseline and samm
 */

'use strict';

const { parseCsv } = require('./csv-utils');

const STATE_ORDER = ['Idle', 'Ramp', 'Burst', 'Cooldown'];

/**
 * Parses markov_transition_matrix.csv into a nested lookup table
 * matrix[currentState][nextState] = probability
 */

function parseTransitionMatrix(csvText){
  const { headers, rows } = parseCsv(csvText);
  const stateColumns = headers.slice(1);

  const matrix = {};
  for (const row of rows){
    const fromState = row[0]
    matrix[fromState] = {};
    stateColumns.forEach((toState, i) => {
      matrix[fromState][toState] = Number(row[i + 1]);
    });
  }
  return matrix;
}

/**
 * Calculates how intense each state is relative to the busiest state (burst)
 * Returns a profile of values between 0.0 and 1.0
 */

function deriveStateIntensityProfile(seriesCsvText){
  const { headers, rows } = parseCsv(seriesCsvText);
  const stateIdx = headers.indexOf('State');
  const valueIdx = headers.indexOf('Total_Invocations');

  if (stateIdx === -1 || valueIdx === -1){
    throw new Error("deriveStateIntensityProfile: expected 'State' and 'Total_Invocations'");
  }

  const sums = { Idle: 0, Ramp: 0, Burst: 0, Cooldown: 0};
  const counts = { Idle: 0, Ramp: 0, Burst: 0, Cooldown: 0};

  for (const row of rows){
    const state = row[stateIdx];
    const value = Number(row[valueIdx]);
    if (!(state in sums)) continue;
    sums[state] += value;
    counts[state] += 1;
  }

  const means = {};
  for (const state of STATE_ORDER){
    means[state] = counts[state] > 0 ? sums[state] / counts[state] : 0;
  }

  const maxMean = Math.max(...Object.values(means));
  const profile = {};
  for (const state of STATE_ORDER){
    profile[state] = maxMean > 0 ? means[state] / maxMean : 0;
  }
  
  return profile;
}

/**
 * Maps the 0.0 - 1.0 intensity onto the actual Request Per Second (RPS)
 * limits of your specific server hardware (e.g., Min 5 RPS, Max 200 RPS)
 */

function scaleToRpsRange(intensityProfile, minRps, maxRps){
  const scaled = {};
  for (const state of STATE_ORDER){
    const t = intensityProfile[state] !== undefined ? intensityProfile[state] : 0;
    scaled[state] = minRps + t * (maxRps - minRps);
  }

  return scaled;
}

/**
 * A seedable PRNG
 * Standard Math.random() cannot be seeded in JS. We need this so 
 * we can reproduce the exact same burst sequence during testing
 */

function makeRng(seed){
  if (seed === undefined || seed === null) return Math.random;
  let state = seed >>> 0;
  return function rng(){
    state |= 0;
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0 ) / 4294967296;
  };
}


/**
 * uses the markov probabilities to pick the next traffic state
 */

function nextState(matrix, currentState, rng){
  const row = matrix[currentState];
  const rand = rng();
  let cumulative = 0;
  for (const state of STATE_ORDER){
    const p = row[state] !== undefined ? row[state] : 0;
    cumulative += p;
    if (rand <= cumulative ) return state;
  }
  return currentState;
}


/**
 * Simulates X minutes of traffic by walking through the markov chain
 */

function simulateSchedule(matrix, rpsProfile, totalMinutes, initialState, seed){
  const rng = makeRng(seed);
  const schedule = [];
  let state = initialState || 'Idle';

  for (let minute = 0; minute < totalMinutes; minute += 1){
    schedule.push({ minute, state, rps: rpsProfile[state] });
    state = nextState(matrix, state, rng);
  }

  return schedule;
}

/**
 * compresses minute-by-minute schedules into k6 target stages.
 * if 5 minutes in a row all have the same RPS, it merges them into a single '5m' stage.
 */
function buildK6Stages(schedule, mergeTolerance = 0.5) {
    if (schedule.length === 0) return [];
    
    const stages = [];
    let currentTarget = Math.round(schedule[0].rps);
    let currentDurationMin = 1;

    for (let i = 1; i < schedule.length; i += 1) {
        const target = Math.round(schedule[i].rps);
        if (Math.abs(target - currentTarget) <= mergeTolerance) {
            currentDurationMin += 1; // Merge consecutive similar states
        } else {
            stages.push({ target: currentTarget, duration: `${currentDurationMin}m` });
            currentTarget = target;
            currentDurationMin = 1;
        }
    }
    stages.push({ target: currentTarget, duration: `${currentDurationMin}m` });

    return stages;
}

module.exports = {
    STATE_ORDER,
    parseTransitionMatrix,
    deriveStateIntensityProfile,
    scaleToRpsRange,
    simulateSchedule,
    buildK6Stages,
    makeRng,
};