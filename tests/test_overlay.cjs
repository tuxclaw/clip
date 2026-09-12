const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(`${__dirname}/../Overlay.qml`, 'utf8');
const functions = source.slice(source.indexOf('  function storageCommand('), source.indexOf('  function reloadState('));
let url = 'file:///tmp/clip%20test/storage.py';
const context = vm.createContext({Qt: {resolvedUrl: () => url}, errorMessage: ''});
vm.runInContext(functions, context);
for (const operation of ['dump', 'pin', 'delete', 'clear']) {
  assert.deepEqual(Array.from(context.storageCommand(operation)), [
    '/usr/bin/timeout', '--kill-after=1s', '2s', '/usr/bin/python3', '-I',
    '/tmp/clip test/storage.py', operation,
  ]);
}
for (url of ['file:///tmp/%2e%2e/storage.py', 'file:///tmp/foo..bar/storage.py',
             'file:///tmp/storage.py.bak', 'https://host/storage.py',
             'file://relative/storage.py', 'file:///tmp/%zz/storage.py']) {
  assert.equal(context.storageCommand('dump').length, 0);
  assert.match(context.errorMessage, /Could not launch/);
}
const signals = [];
const process = {running: true, signal: value => signals.push(value)};
context.stopStorageProcess(process);
assert.equal(process.running, false);
assert.deepEqual(signals, [9]);
context.stopStorageProcess(process);
assert.deepEqual(signals, [9]);
const fallback = {running: true};
context.stopStorageProcess(fallback);
assert.equal(fallback.running, false);
assert.equal((source.match(/clearEnvironment: true/g) || []).length, 2);
assert.equal((source.match(/environment: \(\{ HOME: Quickshell.env\("HOME"\), PATH: "\/usr\/bin:\/bin", LC_ALL: "C" \}\)/g) || []).length, 2);
assert.equal((source.match(/workingDirectory: "\/"/g) || []).length, 2);
for (const id of ['stateDump', 'storage']) {
  assert.match(source, new RegExp(`interval: 4000\\s+repeat: false\\s+running: ${id}.running\\s+onTriggered: root.stopStorageProcess\\(${id}\\)`));
}
assert.doesNotMatch(source, /FileView|\["python3"/);
console.log('Overlay command, path rejection, environment and watchdog checks passed');
