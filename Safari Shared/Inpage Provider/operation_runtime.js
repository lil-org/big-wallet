// ∅ 2026 lil org

"use strict";

const applyFunction = Reflect.apply;
const pushArrayNormally = Array.prototype.push;
const deleteMapEntryNormally = Map.prototype.delete;
const forEachMapNormally = Map.prototype.forEach;
const getMapEntryNormally = Map.prototype.get;
const hasMapEntryNormally = Map.prototype.has;
const setMapEntryNormally = Map.prototype.set;
const freezeObjectNormally = Object.freeze;
const setPrototypeOfNormally = Object.setPrototypeOf;
const getWeakMapValueNormally = WeakMap.prototype.get;
const setWeakMapValueNormally = WeakMap.prototype.set;
const ErrorConstructor = Error;
const MapConstructor = Map;
const RangeErrorConstructor = RangeError;
const TypeErrorConstructor = TypeError;
const defaultMaximumLoadingOperations = 64;
const maximumWireId = Number.MAX_SAFE_INTEGER;
const recordStates = new WeakMap;

function operationQueue() {
    const queue = [];
    setPrototypeOfNormally(queue, null);
    return queue;
}

function getMapEntry(map, key) {
    return applyFunction(getMapEntryNormally, map, [key]);
}

function hasMapEntry(map, key) {
    return applyFunction(hasMapEntryNormally, map, [key]);
}

function setMapEntry(map, key, value) {
    applyFunction(setMapEntryNormally, map, [key, value]);
}

function deleteMapEntry(map, key) {
    applyFunction(deleteMapEntryNormally, map, [key]);
}

class OperationRuntime {

    #generation;
    #nextWireId = 1;
    #operations = new MapConstructor;
    #phase = "loading";
    #queue = operationQueue();
    #loadingAdmissionCount = 0;
    #loadingError;
    #maximumLoadingOperations;
    #retirementError;
    #wireIdStep = 1;

    constructor(generation, {
        firstWireId = 1,
        maximumLoadingOperations = defaultMaximumLoadingOperations,
        wireIdStep = 1,
    } = {}) {
        if (!Number.isSafeInteger(firstWireId) || firstWireId <= 0 ||
            !Number.isSafeInteger(maximumLoadingOperations) ||
            maximumLoadingOperations <= 0 ||
            !Number.isSafeInteger(wireIdStep) || wireIdStep <= 0) {
            throw new TypeErrorConstructor("Invalid operation runtime options");
        }
        this.#generation = generation;
        this.#maximumLoadingOperations = maximumLoadingOperations;
        this.#nextWireId = firstWireId;
        this.#wireIdStep = wireIdStep;
    }

    static get maximumLoadingOperations() {
        return defaultMaximumLoadingOperations;
    }

    get generation() {
        return this.#generation;
    }

    get phase() {
        return this.#phase;
    }

    register({originalId, payload, metadata} = {}) {
        if (this.#phase === "failed") { throw this.#loadingError; }
        if (this.#phase === "retired") {
            throw this.#retirementError ||
                new ErrorConstructor("Operation runtime retired");
        }
        if (this.#nextWireId > maximumWireId) {
            throw new RangeErrorConstructor("Operation wire ID space exhausted");
        }
        const wireId = this.#nextWireId;
        this.#nextWireId = wireId > maximumWireId - this.#wireIdStep
            ? maximumWireId + 1
            : wireId + this.#wireIdStep;
        let resolvePromise;
        let rejectPromise;
        const promise = new Promise((resolve, reject) => {
            resolvePromise = resolve;
            rejectPromise = reject;
        });
        let record;
        record = freezeObjectNormally({
            generation: this.#generation,
            metadata,
            originalId,
            payload,
            promise,
            reject: error => this.reject(record, error),
            resolve: value => this.resolve(record, value),
            wireId,
        });
        setMapEntry(this.#operations, wireId, record);
        applyFunction(setWeakMapValueNormally, recordStates, [record, {
            dispatching: false,
            owned: true,
            queued: false,
            rejectPromise,
            resolvePromise,
            runtime: this,
            wireId,
        }]);
        return record;
    }

    owns(record) {
        const state = applyFunction(getWeakMapValueNormally, recordStates, [record]);
        return !!state && state.runtime === this && state.owned &&
            getMapEntry(this.#operations, state.wireId) === record;
    }

    operation(wireId) {
        return getMapEntry(this.#operations, wireId);
    }

    enqueue(record) {
        if (this.#phase === "ready" || this.#phase === "retired" ||
            this.#phase === "failed" ||
            !this.owns(record)) {
            return false;
        }
        const state = applyFunction(getWeakMapValueNormally, recordStates, [record]);
        if (state.queued || state.dispatching) { return false; }
        if (this.#loadingAdmissionCount >= this.#maximumLoadingOperations) {
            return false;
        }
        this.#loadingAdmissionCount += 1;
        state.queued = true;
        applyFunction(pushArrayNormally, this.#queue, [record]);
        return true;
    }

    drain(dispatch) {
        if (typeof dispatch !== "function") {
            throw new TypeErrorConstructor("Operation dispatch must be a function");
        }
        if (this.#phase === "retired" || this.#phase === "ready" ||
            this.#phase === "draining") {
            return 0;
        }
        this.#phase = "draining";
        this.#loadingError = undefined;
        let dispatched = 0;
        let drainingQueue = this.#queue;
        let queueIndex = 0;
        try {
            while (this.#phase === "draining") {
                if (drainingQueue !== this.#queue) {
                    drainingQueue = this.#queue;
                    queueIndex = 0;
                }
                if (queueIndex >= drainingQueue.length) { break; }
                const record = drainingQueue[queueIndex];
                drainingQueue[queueIndex] = null;
                queueIndex += 1;
                const state = applyFunction(
                    getWeakMapValueNormally,
                    recordStates,
                    [record]
                );
                if (!state || state.runtime !== this || !state.owned ||
                    !state.queued || !this.owns(record)) {
                    continue;
                }
                state.queued = false;
                state.dispatching = true;
                try {
                    dispatch(record);
                    dispatched += 1;
                } catch (error) {
                    this.reject(record, error);
                } finally {
                    state.dispatching = false;
                }
            }
        } finally {
            this.#queue = operationQueue();
            this.#loadingAdmissionCount = 0;
            if (this.#phase === "draining") {
                this.#phase = "ready";
            }
        }
        return dispatched;
    }

    resolve(record, value) {
        const settlement = this.#take(record);
        if (!settlement) { return false; }
        settlement.resolvePromise(value);
        return true;
    }

    reject(record, error) {
        const settlement = this.#take(record);
        if (!settlement) { return false; }
        settlement.rejectPromise(error);
        return true;
    }

    rejectAll(error) {
        const records = operationQueue();
        applyFunction(forEachMapNormally, this.#operations, [record => {
            applyFunction(pushArrayNormally, records, [record]);
        }]);
        this.#operations = new MapConstructor;
        this.#queue = operationQueue();
        this.#loadingAdmissionCount = 0;
        const settlements = operationQueue();
        for (let index = 0; index < records.length; index += 1) {
            const record = records[index];
            const state = applyFunction(
                getWeakMapValueNormally,
                recordStates,
                [record]
            );
            if (!state || state.runtime !== this || !state.owned) { continue; }
            state.dispatching = false;
            state.owned = false;
            state.queued = false;
            applyFunction(pushArrayNormally, settlements, [state.rejectPromise]);
        }
        for (let index = 0; index < settlements.length; index += 1) {
            settlements[index](error);
        }
        return settlements.length;
    }

    failLoading(error) {
        if (this.#phase !== "loading") { return false; }
        this.#phase = "failed";
        this.#loadingError = error;
        this.rejectAll(error);
        return true;
    }

    retire(error = new ErrorConstructor("Operation runtime retired")) {
        if (this.#phase === "retired") { return 0; }
        this.#phase = "retired";
        this.#retirementError = error;
        return this.rejectAll(error);
    }

    #take(record) {
        const state = applyFunction(getWeakMapValueNormally, recordStates, [record]);
        if (!state || state.runtime !== this || !state.owned ||
            !hasMapEntry(this.#operations, state.wireId) ||
            getMapEntry(this.#operations, state.wireId) !== record) {
            return null;
        }
        deleteMapEntry(this.#operations, state.wireId);
        state.dispatching = false;
        state.owned = false;
        state.queued = false;
        return state;
    }
}

export { OperationRuntime };
export default OperationRuntime;
