const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
let rendered;
const context = vm.createContext({window:{}, Date, Intl, Map, Number, console,
  Plotly:{react:(_target,traces,layout)=>{rendered={traces,layout};}}});
vm.runInContext(fs.readFileSync('web/assets/station-rates.js','utf8'),context);
const rates = context.window.SofuRates;
const payload = {recent_series:[
  {timestamp:'2026-11-01T00:00:00-06:00',precip_accum:8},
  {timestamp:'2026-11-01T01:00:00-06:00',precip_accum:.1},
  {timestamp:'2026-11-01T01:00:00-06:00',precip_accum:.2},
  {timestamp:'2026-11-01T01:00:00-07:00',precip_accum:0},
  {timestamp:'2026-11-01T03:00:00-07:00',precip_accum:.3}
]};
const points = rates.chartPoints(payload,'precip_cumulative',4);
assert.equal(points.length,3);
assert.equal(points.at(-1).observed_accumulation,.5);
rates.renderPlot({},payload,'precip_cumulative',4);
assert.equal(rendered.traces[0].type,'scatter');
assert.equal(rendered.traces[0].y.at(-1),.5);
assert(rendered.traces[0].y.includes(null));
assert.match(rendered.layout.yaxis.title,/selected window/);
rates.renderPlot({},payload,'precip_accum',4);
assert.equal(rendered.traces[0].type,'bar');
assert.match(rendered.layout.yaxis.title,/hour interval/);
console.log('PASS: running precipitation accumulation, hourly deduplication, DST hours, window boundary, visible gaps, daily bars unchanged');
