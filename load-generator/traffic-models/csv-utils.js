'use strict';


// This file takes raw text from CVS File and turn it into usable JavaScript arrays and objects.

/* 
  NOTE ON THE MODULE FORMAT:
  We use standard CommonJS ('module.exports') instead of ES6 `export`
  Why? Because we want to run unit tests on these math modules using
  standard Node.js later (text-fixtures/run-test.js). Grafana k6 suppports
  require (), so writing it this way makes the code protable across both environments.
*/

/**
  Minimal CSV parser for flat, unquoted numeric CSVs.

  @param {string} text - The raw string contents of the CVS file.
  @returns {Object} { headers: string[], rows: string[][] }
*/

function parseCsv(text){
  const lines = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);

    if (lines.length == 0){
      return {headers: [], rows: []};
    }

    const headers = lines[0].split(',');

    const rows = lines.slice(1).map((line) => line.split(','));

    return { headers, rows };
}


// converts parsed csv rows into an array of JS objects keyed by header name
// example output: [ { HashApp: 'abc', P50: 10, P99: 100 }]

function rowsToObjects(headers, rows){
  return rows.map((row) =>{
    const obj = {};
    
    headers.forEach((header, i) => {
      const raw = row[i] !== undefined ? row[i] : '';

      if (raw === ''){
        obj[header] = '';
      } else {
        const num = Number(raw);
        obj[header] = Number.isNaN(num) ? raw : num;
      }
    });
    return obj;
  });
}

module.exports = {
  parseCsv,
  rowsToObjects
};
