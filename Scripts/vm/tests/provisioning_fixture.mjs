import {createHash, randomUUID} from 'node:crypto';
import * as provisioning from '../provision_guest.mjs';
import assert from 'node:assert/strict';

export function provisionerFixture({config = {consoleUser: 'tester'}, staging = '/guest/provision', uid = 501, gid = 20, mode = '', repairPlatforms = [],
    library = '/guest/library', state = '/guest/state', exchange = '/Volumes/BigWalletBuild/Exchange',
    developer = '/Applications/Xcode.app/Contents/Developer', environment = {}, fs = {}, run,
    spawnSync = () => assert.fail('Unexpected subprocess'), crypto = {createHash, randomUUID},
    process: processEffects = {pid: process.pid, stdout: {write() {}}, stderr: {write() {}}, on() {}},
    performance = {now: () => 0}, console = {log() {}, error() {}}, setImmediate = () => {}} = {}) {
    return provisioning.createProvisioner({config, staging, uid, gid, mode, repairPlatforms, environment,
        paths: {library, state, exchange, developer}},
        {fs, execute: run, spawnSync, crypto, process: processEffects, performance, console, setImmediate});
}
