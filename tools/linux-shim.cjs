"use strict";
// Linux port: polyfill Electron APIs that only exist on macOS/Windows but are called unconditionally.
const { systemPreferences } = require("electron");
const shim = (name, fn) => { if (typeof systemPreferences[name] !== "function") systemPreferences[name] = fn; };
shim("getMediaAccessStatus", () => "granted");        // Linux has no OS-level media permission
shim("askForMediaAccess", async () => true);
shim("isTrustedAccessibilityClient", () => true);
