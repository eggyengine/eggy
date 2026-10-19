const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(`${__dirname}/storage_browser.js`, "utf8");

function bridge(store = new Map(), localStorage) {
    const memory = new Uint8Array(1024);
    const storage = localStorage ?? {
        get length() { return store.size; },
        getItem(key) { return store.get(key) ?? null; },
        setItem(key, value) { store.set(key, value); },
        removeItem(key) { store.delete(key); },
    };
    const invoke = vm.runInNewContext(`(${source})`, {
        localStorage: storage, HEAPU8: memory, atob, btoa,
    });
    return { invoke, memory };
}

test("persistent browser bridge roundtrips bytes across bridge instances", () => {
    const store = new Map();
    const first = bridge(store);
    first.memory.set([0, 255, 128, 65], 10);
    assert.equal(first.invoke("check", "", 0, 0), 0);
    assert.equal(first.invoke("write", "eggy.save.project.slot", 10, 4), 0);
    const reloaded = bridge(store);
    const capacity = reloaded.invoke("size", "eggy.save.project.slot", 0, 1024);
    assert.equal(reloaded.invoke("read", "eggy.save.project.slot", 0, capacity), 4);
    assert.deepEqual([...reloaded.memory.subarray(0, 4)], [0, 255, 128, 65]);
    first.memory.set([42], 0);
    assert.equal(first.invoke("write", "eggy.save.project.slot", 0, 1), 0);
    assert.equal(store.size, 1);
    assert.equal(reloaded.invoke("remove", "eggy.save.project.slot", 0, 0), 0);
    assert.equal(reloaded.invoke("size", "eggy.save.project.slot", 0, 1024), -5);
    assert.equal(reloaded.invoke("remove", "eggy.save.project.slot", 0, 0), -5);
});

test("browser slots isolate projects and reject corrupt and oversized values", () => {
    const store = new Map([["a", "%%%="], ["large", "AAAAAAAA"]]);
    const { invoke } = bridge(store);
    assert.equal(invoke("size", "b", 0, 1024), -5);
    assert.equal(invoke("read", "a", 0, 4), -3);
    assert.equal(invoke("size", "large", 0, 4), -6);
    assert.equal(invoke("read", "large", 0, 1), -4);
});

test("denied persistence is unsupported and quota failures retain old saves", () => {
    const denied = bridge(new Map(), {
        get length() { throw new DOMException("denied", "SecurityError"); },
    });
    assert.equal(denied.invoke("check", "", 0, 0), -1);
    const store = new Map([["slot", "old"]]);
    const full = bridge(store, {
        setItem() { throw new DOMException("full", "QuotaExceededError"); },
    });
    assert.equal(full.invoke("write", "slot", 0, 0), -2);
    assert.equal(store.get("slot"), "old");
    const unavailable = vm.runInNewContext(`(${source})`, {});
    assert.equal(unavailable("check", "", 0, 0), -1);
});
