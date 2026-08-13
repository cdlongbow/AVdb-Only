define([
    "events",
    "connectionManager"
], function (events, connectionManager) {
    "use strict";

    // This module is deliberately limited to lifecycle and protocol work. It
    // does not know about feature DOM, styles, or business endpoints.
    var LOADER_VERSION = 1;
    var CLIENT_API_VERSION = 1;
    var CONFIG_PATH = "Plugins/AvdbMagicTools/Client/Config";
    var SCRIPT_PATH = "Plugins/AvdbMagicTools/Client/Script";
    var CONFIG_TIMEOUT_MS = 8000;
    var SCRIPT_TIMEOUT_MS = 8000;
    var CONNECTION_EVENTS = [
        "apiclientcreated",
        "localusersignedin",
        "serverconnected",
        "serverchange",
        "connectionchange",
        "serverdisconnected",
        "localusersignedout"
    ];
    var ROOT = typeof globalThis !== "undefined"
        ? globalThis
        : typeof window !== "undefined" ? window : {};
    var state = {
        apiClient: null,
        connectionManager: null,
        events: null,
        serverId: null,
        config: null,
        enabled: false,
        initialized: false,
        initializing: false,
        reason: "not-started",
        generation: 0,
        initPromise: null,
        client: null,
        subscriptions: [],
        timeoutIds: []
    };

    function log(level, message, detail) {
        var logger = ROOT.console && ROOT.console[level]
            ? ROOT.console[level]
            : ROOT.console && ROOT.console.log;

        if (!logger) {
            return;
        }

        if (typeof detail === "undefined") {
            logger.call(ROOT.console, "[Avdb Magic Tools Loader] " + message);
        } else {
            logger.call(ROOT.console, "[Avdb Magic Tools Loader] " + message, detail);
        }
    }

    function isApiClient(value) {
        return !!value
            && typeof value.getUrl === "function"
            && typeof value.getJSON === "function";
    }

    function resolveEvents(context) {
        if (context && context.events) {
            return context.events;
        }

        return events || ROOT.Events || ROOT.events || null;
    }

    function resolveConnectionManager(context) {
        if (context && context.connectionManager) {
            return context.connectionManager;
        }

        return connectionManager || ROOT.ConnectionManager || null;
    }

    function resolveApiClient(context, manager) {
        var candidate = context && context.apiClient;

        if (isApiClient(candidate)) {
            return candidate;
        }

        manager = manager || resolveConnectionManager(context);
        if (manager && typeof manager.currentApiClient === "function") {
            try {
                candidate = manager.currentApiClient();
                if (isApiClient(candidate)) {
                    return candidate;
                }
            } catch (error) {
                log("warn", "无法读取当前 ApiClient");
            }
        }

        return isApiClient(ROOT.ApiClient) ? ROOT.ApiClient : null;
    }

    function getServerId(apiClient) {
        var value;

        if (!apiClient) {
            return null;
        }

        try {
            if (typeof apiClient.serverId === "function") {
                value = apiClient.serverId();
            } else if (typeof apiClient.serverId === "string") {
                value = apiClient.serverId;
            }
        } catch (error) {
            value = null;
        }

        if (!value && apiClient._serverInfo && apiClient._serverInfo.Id) {
            value = apiClient._serverInfo.Id;
        }

        if (!value && typeof apiClient.serverInfo === "function") {
            try {
                value = apiClient.serverInfo();
            } catch (error) {
                value = null;
            }
        }

        if (value && typeof value === "object") {
            value = value.Id || value.id || value.ServerId || value.serverId;
        }

        return value === null || typeof value === "undefined"
            ? null
            : String(value);
    }

    function clearTimeouts() {
        for (var index = 0; index < state.timeoutIds.length; index += 1) {
            ROOT.clearTimeout(state.timeoutIds[index]);
        }

        state.timeoutIds = [];
    }

    function removeTimeout(timeoutId) {
        state.timeoutIds = state.timeoutIds.filter(function (candidate) {
            return candidate !== timeoutId;
        });
    }

    function request(apiClient, path, method, timeoutMs) {
        var url;

        if (!isApiClient(apiClient) || typeof apiClient[method] !== "function") {
            return Promise.reject(new Error("ApiClient unavailable"));
        }

        try {
            url = apiClient.getUrl(path);
        } catch (error) {
            return Promise.reject(error);
        }

        return new Promise(function (resolve, reject) {
            var settled = false;
            var timeoutId = ROOT.setTimeout(function () {
                removeTimeout(timeoutId);
                if (!settled) {
                    settled = true;
                    reject(new Error("Client request timed out"));
                }
            }, timeoutMs);

            state.timeoutIds.push(timeoutId);

            Promise.resolve()
                .then(function () {
                    return method === "getText"
                        ? apiClient.getText(url)
                        : apiClient.getJSON(url);
                })
                .then(function (result) {
                    if (settled) {
                        return;
                    }

                    settled = true;
                    ROOT.clearTimeout(timeoutId);
                    removeTimeout(timeoutId);
                    resolve(result);
                })
                .catch(function (error) {
                    if (settled) {
                        return;
                    }

                    settled = true;
                    ROOT.clearTimeout(timeoutId);
                    removeTimeout(timeoutId);
                    reject(error);
                });
        });
    }

    function getConfig(apiClient) {
        return request(apiClient, CONFIG_PATH, "getJSON", CONFIG_TIMEOUT_MS);
    }

    function getClientScript(apiClient, config) {
        var pluginVersion = readField(config, "PluginVersion", "pluginVersion");
        var path = SCRIPT_PATH;
        if (pluginVersion) {
            path += "?v=" + encodeURIComponent(String(pluginVersion));
        }
        return request(apiClient, path, "getText", SCRIPT_TIMEOUT_MS);
    }

    function removeClientGlobal(client) {
        if (!client || ROOT.AvdbMagicToolsClient !== client) {
            return;
        }

        try {
            delete ROOT.AvdbMagicToolsClient;
        } catch (error) {
            ROOT.AvdbMagicToolsClient = null;
        }
    }

    function destroyClient() {
        var client = state.client || ROOT.AvdbMagicToolsClient;

        if (client && typeof client.destroy === "function") {
            try {
                client.destroy();
            } catch (error) {
                log("warn", "Client Core destroy 失败，已隔离");
            }
        }

        removeClientGlobal(client);
        state.client = null;
    }

    function executeClientScript(source, context) {
        var execute;
        var client;

        if (typeof source !== "string" || !source.trim()) {
            throw new Error("Client script is empty");
        }

        // Keep server-delivered code in its own function boundary. A syntax
        // or runtime error here is caught by init() and cannot break Emby.
        execute = new Function(source);
        execute();
        client = ROOT.AvdbMagicToolsClient;

        if (!client
            || typeof client.init !== "function"
            || typeof client.destroy !== "function") {
            throw new Error("Client Core lifecycle API is incomplete");
        }

        state.client = client;
        return Promise.resolve(client.init(context));
    }

    function readField(config, upperName, lowerName) {
        if (!config) {
            return undefined;
        }

        return typeof config[upperName] !== "undefined"
            ? config[upperName]
            : config[lowerName];
    }

    function checkCompatibility(config) {
        var enabled = readField(config, "Enabled", "enabled");
        var apiVersion = Number(readField(config, "ClientApiVersion", "clientApiVersion"));
        var minLoaderVersion = Number(
            readField(config, "MinLoaderVersion", "minLoaderVersion")
        );
        var pluginVersion = readField(config, "PluginVersion", "pluginVersion");

        if (!config || enabled !== true) {
            return { ok: false, reason: "server-disabled" };
        }

        if (apiVersion !== CLIENT_API_VERSION) {
            return { ok: false, reason: "client-api-version-incompatible" };
        }

        if (!isFinite(minLoaderVersion) || minLoaderVersion > LOADER_VERSION) {
            return { ok: false, reason: "loader-version-incompatible" };
        }

        if (!pluginVersion) {
            return { ok: false, reason: "plugin-version-missing" };
        }

        return { ok: true, reason: "ready" };
    }

    function snapshot() {
        return {
            loaderVersion: LOADER_VERSION,
            clientApiVersion: CLIENT_API_VERSION,
            initialized: state.initialized,
            initializing: state.initializing,
            enabled: state.enabled,
            reason: state.reason,
            serverId: state.serverId,
            pluginVersion: state.config
                ? readField(state.config, "PluginVersion", "pluginVersion") || null
                : null,
            config: state.config
        };
    }

    function unsubscribeAll() {
        var subscriptions = state.subscriptions.slice();
        state.subscriptions = [];

        for (var index = 0; index < subscriptions.length; index += 1) {
            try {
                subscriptions[index]();
            } catch (error) {
                log("warn", "移除连接监听失败");
            }
        }
    }

    function subscribe(bus, target, eventName, handler) {
        var unsubscribe;

        if (!bus) {
            return;
        }

        if (typeof bus.on === "function") {
            bus.on(target, eventName, handler);
            unsubscribe = function () {
                if (typeof bus.off === "function") {
                    bus.off(target, eventName, handler);
                } else if (typeof bus.removeListener === "function") {
                    bus.removeListener(target, eventName, handler);
                }
            };
        } else if (typeof bus.addEventListener === "function") {
            bus.addEventListener(eventName, handler);
            unsubscribe = function () {
                if (typeof bus.removeEventListener === "function") {
                    bus.removeEventListener(eventName, handler);
                }
            };
        }

        if (unsubscribe) {
            state.subscriptions.push(unsubscribe);
        }
    }

    function findApiClient(args) {
        for (var index = 0; index < args.length; index += 1) {
            if (isApiClient(args[index])) {
                return args[index];
            }
        }

        return null;
    }

    function resetRuntime(reason) {
        state.generation += 1;
        clearTimeouts();
        destroyClient();
        state.initPromise = null;
        state.initialized = false;
        state.initializing = false;
        state.enabled = false;
        state.reason = reason || "destroyed";
        state.apiClient = null;
        state.serverId = null;
        state.config = null;
    }

    function destroy() {
        unsubscribeAll();
        resetRuntime("destroyed");
        log("log", "已销毁当前服务器运行时");
        return snapshot();
    }

    function handleConnectionEvent(eventName, args) {
        var nextApiClient = findApiClient(args);
        var nextServerId;

        if (eventName === "serverdisconnected" || eventName === "localusersignedout") {
            resetRuntime("server-disconnected");
            return;
        }

        nextApiClient = nextApiClient || resolveApiClient(null, state.connectionManager);
        if (!nextApiClient) {
            resetRuntime("api-client-unavailable");
            return;
        }

        nextServerId = getServerId(nextApiClient);
        if (state.apiClient !== nextApiClient
            || (state.serverId && nextServerId && state.serverId !== nextServerId)) {
            // A server switch is an explicit destroy -> init boundary. The
            // watcher is rebound by init so no old runtime can survive it.
            destroy();
            init({
                apiClient: nextApiClient,
                connectionManager: state.connectionManager || connectionManager,
                events: state.events || events
            });
            return;
        }

        if (!state.initialized && !state.initializing) {
            init({
                apiClient: nextApiClient,
                connectionManager: state.connectionManager || connectionManager,
                events: state.events || events
            });
        }
    }

    function bindConnectionEvents() {
        var eventBus = state.events;
        var manager = state.connectionManager;

        if (!eventBus || !manager || state.subscriptions.length) {
            return;
        }

        // Emby's events module uses events.on(target, name, callback). Keep
        // one callback per event so off() can be exact during destroy().
        for (var index = 0; index < CONNECTION_EVENTS.length; index += 1) {
            (function (eventName) {
                var callback = function () {
                    handleConnectionEvent(
                        eventName,
                        Array.prototype.slice.call(arguments)
                    );
                };
                subscribe(eventBus, manager, eventName, callback);
            })(CONNECTION_EVENTS[index]);
        }
    }

    function init(context) {
        context = context || {};
        state.events = resolveEvents(context);
        state.connectionManager = resolveConnectionManager(context);

        var apiClient = resolveApiClient(context, state.connectionManager);
        var serverId = getServerId(apiClient);

        bindConnectionEvents();

        if (!apiClient) {
            state.reason = "api-client-unavailable";
            state.enabled = false;
            log("warn", "ApiClient 不可用，保持普通 Emby");
            return Promise.resolve(snapshot());
        }

        if (state.initialized
            && state.apiClient === apiClient
            && state.serverId === serverId) {
            return Promise.resolve(snapshot());
        }

        if (state.initializing
            && state.apiClient === apiClient
            && state.serverId === serverId
            && state.initPromise) {
            return state.initPromise;
        }

        if (state.initialized || state.initializing) {
            destroy();
            state.events = resolveEvents(context);
            state.connectionManager = resolveConnectionManager(context);
            bindConnectionEvents();
        }

        state.apiClient = apiClient;
        state.serverId = serverId;
        state.initializing = true;
        state.reason = "config-loading";
        state.enabled = false;
        var generation = state.generation;

        state.initPromise = getConfig(apiClient)
            .then(function (config) {
                if (generation !== state.generation) {
                    return snapshot();
                }

                var compatibility = checkCompatibility(config);
                state.config = config;
                state.initialized = true;
                state.initializing = false;
                state.enabled = compatibility.ok;
                state.reason = compatibility.reason;

                if (compatibility.ok) {
                    log("log", "服务器 Config 握手成功");
                    return getClientScript(apiClient, config)
                        .then(function (source) {
                            if (generation !== state.generation) {
                                return snapshot();
                            }

                            return executeClientScript(source, {
                                apiClient: state.apiClient,
                                serverId: state.serverId,
                                config: state.config,
                                events: state.events,
                                connectionManager: state.connectionManager,
                                loaderVersion: LOADER_VERSION
                            });
                        })
                        .then(function () {
                            if (generation !== state.generation) {
                                return snapshot();
                            }

                            state.initialized = true;
                            state.initializing = false;
                            state.enabled = true;
                            state.reason = "ready";
                            log("log", "Client Script 已加载");
                            return snapshot();
                        }, function (error) {
                            if (generation === state.generation) {
                                destroyClient();
                                state.initialized = true;
                                state.initializing = false;
                                state.enabled = false;
                                state.reason = "client-script-failed";
                                log("warn", "Client Script 失败，保持普通 Emby");
                            }

                            return snapshot();
                        });
                } else {
                    state.initialized = true;
                    state.initializing = false;
                    log("warn", "服务器协议不兼容，已停止加载", compatibility.reason);
                }

                return snapshot();
            })
            .catch(function (error) {
                if (generation === state.generation) {
                    state.initialized = false;
                    state.initializing = false;
                    state.enabled = false;
                    state.reason = "config-request-failed";
                    state.config = null;
                    log("warn", "Config 请求失败，保持普通 Emby");
                }

                return snapshot();
            });

        return state.initPromise;
    }

    var api = {
        LOADER_VERSION: LOADER_VERSION,
        CLIENT_API_VERSION: CLIENT_API_VERSION,
        init: init,
        destroy: destroy,
        getState: snapshot
    };

    ROOT.AvdbMagicToolsLoader = api;

    function AvdbMagicToolsLoaderPlugin() {
        this.id = "avdb-magic-tools-loader";
        this.name = "Avdb Magic Tools Loader";
        this.type = "client-loader";
        init();
    }

    return AvdbMagicToolsLoaderPlugin;
});
