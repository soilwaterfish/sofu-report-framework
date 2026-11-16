const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
class FixedDate extends Date { static now() { return Date.parse('2026-11-10T18:00:00Z'); } }
const context = vm.createContext({window:{}, document:{body:{dataset:{}},scripts:[]},
  console, Date:FixedDate, Intl, URL, Map, Set, Number, encodeURIComponent});
vm.runInContext(fs.readFileSync('web/assets/station-rates.js','utf8'),context);
vm.runInContext(fs.readFileSync('web/assets/app.js','utf8').replace(/\ninit\(\);\s*$/, ''),context);
context.timestampStation={latest:{timestamp:'2026-11-16T12:00:00-07:00'},
  latest_dates:{air_temp:'2026-11-16T06:00:00-07:00',gsi:'2026-11-16T12:00:00-07:00',precip_cumulative:'2026-11-16T12:00:00-07:00'}};
assert.equal(vm.runInContext('latestObservationTimestamp(timestampStation)',context),'2026-11-16T06:00:00-07:00');
context.timestampStation.latest_dates={gsi:'2026-11-16T12:00:00-07:00'};
assert.equal(vm.runInContext('latestObservationTimestamp(timestampStation)',context),'2026-11-16T12:00:00-07:00');
vm.runInContext(`state.data={generated_at:'2026-11-10T05:00:00-07:00'};state.metric='precip_cumulative';`,context);
assert.equal(vm.runInContext('chartDateRange()[0]',context),'2025-11-10T00:00:00');
vm.runInContext(`state.chartWindow='wy'`,context);
assert.equal(vm.runInContext('chartDateRange()[0]',context),'2026-10-01T00:00:00');
const points = [{timestamp:'2026-09-30',precip_cumulative:15,p10:10,p90:20},
  {timestamp:'2026-10-01',precip_cumulative:0,p10:0,p90:.2}];
context.points=points;
assert.equal(vm.runInContext('addWaterYearBreaks(points,"precip_cumulative")[1].precip_cumulative',context),null);
const ribbon=vm.runInContext('buildPercentileRibbonTrace(points,"p10","p90","#123456","reference",.2)',context);
assert.equal(ribbon.x.filter(x=>x===null).length,2);
const rates=context.window.SofuRates;
const payload={recent_series:[{timestamp:'2026-11-10T00:00:00-07:00',air_temp:10},
  {timestamp:'2026-11-10T01:00:00-07:00',air_temp:20},
  {timestamp:'2026-11-10T02:00:00-07:00',air_temp:null},
  {timestamp:'2026-11-10T03:00:00-07:00',air_temp:30}]};
const snapshot=rates.snapshot(payload,'air_temp');
assert.equal(snapshot.min,10);assert.equal(snapshot.mean,20);assert.equal(snapshot.max,30);
assert.equal(snapshot.samples,3);assert(snapshot.isToday);
context.station={current_report:payload,today_reference:{air_temp:{local_date:'2026-11-10',value_min:{p50:1},value_mean:{p50:2},value_max:{p50:3}}}};
vm.runInContext(`state.metric='air_temp'`,context);
assert.equal(vm.runInContext('provisionalPercentiles(station).value_mean.current',context),20);
assert.equal(vm.runInContext('provisionalPercentiles(station).value_mean.p50',context),2);
context.station.current_report={recent_series:[{timestamp:'2026-11-09T01:00:00-07:00',air_temp:10}]};
assert.equal(vm.runInContext('provisionalPercentiles(station).value_mean.current',context),null);
console.log('PASS: 365-day horizon, water-year view, rollover line/ribbon breaks, today sampled min/mean/max, correct reference statistics, stale observations excluded');
