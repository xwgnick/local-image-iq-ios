import fs from 'node:fs';

const runtimes = JSON.parse(fs.readFileSync('build/store-runtimes.json', 'utf8')).runtimes;
const devices = JSON.parse(fs.readFileSync('build/store-devices.json', 'utf8')).devicetypes;
const runtime = runtimes.find(r => r.isAvailable && r.version === '26.2' && r.identifier.includes('.iOS-'));
if (!runtime) throw Error('Required iOS 26.2 runtime is unavailable');
const selections = [
  ['iphone-medium', 'iPhone 15 Pro'],
  ['iphone-large', 'iPhone 16 Pro Max'],
  ['ipad-13', 'iPad Pro 13-inch (M4)'],
];
const rows = selections.map(([label, name]) => {
  const device = devices.find(d => d.name === name);
  if (!device) throw Error(`Required screenshot device not found: ${name}`);
  return `${label}|${device.identifier}|${runtime.identifier}`;
});
fs.writeFileSync('build/store-devices.txt', rows.join('\n') + '\n');
console.log(rows.join('\n'));
