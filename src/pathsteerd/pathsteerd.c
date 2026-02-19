/*******************************************************************************
 * pathsteerd.c - PathSteer Guardian Edge Daemon
 * 
 * PURPOSE:
 *   This daemon runs on the Edge device (Protectli) and is the "brain" that:
 *   1. Monitors all uplinks (Starlink A/B, Cell A/B, Fiber 1/2)
 *   2. Detects degradation via tripwire triggers
 *   3. Enables traffic duplication via tc mirred
 *   4. Switches between uplinks with flap suppression
 *   5. Learns route risk profiles for prediction
 *   6. Controls the C8000 via SSH for PoP switching
 *   7. Serves status to Web UI via JSON file
 *
 * ARCHITECTURE:
 *   - Each uplink lives in its own network namespace (ns_cell_a, ns_sl_a, etc)
 *   - WireGuard tunnels terminate inside each namespace
 *   - Traffic flows: LAN -> br-lan -> tc mirred -> veth -> namespace -> WG -> PoP
 *   - Duplication: tc mirred sends same packet to multiple veths simultaneously
 *   - Deduplication happens at Controller (not here)
 *
 * OPERATING MODES:
 *   TRAINING   - Observe only, build risk maps, no actuation
 *   TRIPWIRE   - Duplication off until triggered, then one switch per window
 *   MIRROR     - Always-on duplication for maximum stability
 *
 * BUILD:
 *   make
 * 
 * RUN:
 *   ./pathsteerd --config /etc/pathsteer/config.json
 *
 * Copyright (c) 2025 PathSteer Networks
 ******************************************************************************/

#define _GNU_SOURCE

/*=============================================================================
 * INCLUDES
 *===========================================================================*/

#include <stdio.h>
#include <syslog.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <math.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <dirent.h>

#include <sqlite3.h>
#include <curl/curl.h>

/*=============================================================================
 * VERSION AND BUILD INFO
 *===========================================================================*/

#define VERSION         "1.0.0"
#define BUILD_DATE      __DATE__ " " __TIME__

/*=============================================================================
 * CONSTANTS AND LIMITS
 * 
 * These values are defaults that can be overridden by config.json
 * The thresholds here are tuned for mobile/vehicle scenarios
 *===========================================================================*/

/* Maximum number of uplinks we support */
#define MAX_UPLINKS         6

/* Maximum number of controllers (PoPs) */
#define MAX_CONTROLLERS     2

/* History buffer size for RTT/signal measurements */
#define HISTORY_SIZE        100

/* How often we probe each uplink (milliseconds) */
#define PROBE_INTERVAL_MS   100

/* Default tripwire thresholds
 * RTT_STEP: If RTT jumps by this much over baseline, trigger protection
 * PROBE_MISS: If we miss this many consecutive probes, trigger protection
 * RSRP_DROP: If LTE signal drops by this many dB, trigger protection
 * SINR_DROP: If LTE SNR drops by this many dB, trigger protection
 */
#define DEFAULT_RTT_STEP_MS         80
#define DEFAULT_RTT_WINDOW_MS       200
#define DEFAULT_PROBE_MISS_COUNT    2
#define DEFAULT_PROBE_MISS_WINDOW   300
#define DEFAULT_RSRP_DROP_DB        8
#define DEFAULT_SINR_DROP_DB        6

/* Switching parameters
 * PREROLL: Wait this long after triggering before switching (let duplication stabilize)
 * MIN_HOLD: Stay in protection mode for at least this long
 * CLEAN_EXIT: Need this many seconds of "clean" before exiting protection
 */
#define DEFAULT_PREROLL_MS          500
#define DEFAULT_MIN_HOLD_SEC        3
#define DEFAULT_CLEAN_EXIT_SEC      2

/* Risk output interval (how often prediction engine runs) */
#define RISK_INTERVAL_MS            250

/* Duplication settle time: wait at least this long after dup_enable before switching */
#define DUP_SETTLE_MS               50

/* Status file update interval */
#define STATUS_INTERVAL_MS          100

/*=============================================================================
 * TYPE DEFINITIONS
 *===========================================================================*/

/*-----------------------------------------------------------------------------
 * Operating Modes
 * 
 * TRAINING: Passive observation only. We collect data and build risk maps
 *           but NEVER actuate (no tc mirred, no switching). The predictor
 *           runs and produces "would do" decisions for logging.
 *           UI shows: "TRAINING MODE - NO PREDICTIVE ACTUATION"
 *
 * TRIPWIRE: Default operating mode. Duplication is OFF to save bandwidth.
 *           When tripwire fires (RTT spike, probe loss, etc), we:
 *           1. Immediately enable duplication (milliseconds)
 *           2. Start hold timer
 *           3. Arbitrate and switch once
 *           4. Exit after clean period
 *
 * MIRROR:   Maximum stability mode. Duplication is ALWAYS ON.
 *           Switching still uses same logic, but we're always duplicating.
 *           Use for demos or critical sessions.
 *---------------------------------------------------------------------------*/
typedef enum {
    MODE_TRAINING = 0,
    MODE_TRIPWIRE,
    MODE_MIRROR
} op_mode_t;

static const char* MODE_NAMES[] = {"TRAINING", "TRIPWIRE", "MIRROR"};

/*-----------------------------------------------------------------------------
 * System States
 * 
 * NORMAL:     No issues detected, operating normally
 * PREPARE:    Prediction indicates upcoming degradation, pre-arming
 * PROTECT:    Tripwire fired, duplication active, evaluating switch
 * SWITCHING:  In preroll period before executing switch
 * HOLDING:    Switch executed, holding in protection mode
 *---------------------------------------------------------------------------*/
typedef enum {
    STATE_NORMAL = 0,
    STATE_PREPARE,
    STATE_PROTECT,
    STATE_SWITCHING,
    STATE_HOLDING
} sys_state_t;

static const char* STATE_NAMES[] = {"NORMAL", "PREPARE", "PROTECT", "SWITCHING", "HOLDING"};

/*-----------------------------------------------------------------------------
 * Uplink Types
 * 
 * Each uplink has different characteristics:
 * - LTE: Has RF metrics (RSRP, SINR), carrier info, can predict via training
 * - STARLINK: Has dish API (obstruction, latency), unpredictable sat hops
 * - FIBER: Most stable, typically just RTT monitoring
 *---------------------------------------------------------------------------*/
typedef enum {
    UPLINK_TYPE_LTE = 0,
    UPLINK_TYPE_STARLINK,
    UPLINK_TYPE_FIBER
} uplink_type_t;

/*-----------------------------------------------------------------------------
 * Uplink IDs
 * These correspond to the config file uplink names
 *---------------------------------------------------------------------------*/
typedef enum {
    UPLINK_CELL_A = 0,
    UPLINK_CELL_B,
    UPLINK_SL_A,
    UPLINK_SL_B,
    UPLINK_FIBER1,
    UPLINK_FIBER2,
    UPLINK_COUNT
} uplink_id_t;

static const char* UPLINK_NAMES[] = {
    "cell_a", "cell_b", "sl_a", "sl_b", "fa", "fb"
};

/*-----------------------------------------------------------------------------
 * Trigger Reasons
 * What caused the tripwire to fire
 *---------------------------------------------------------------------------*/
typedef enum {
    TRIGGER_NONE = 0,
    TRIGGER_RTT_STEP,           /* RTT jumped significantly */
    TRIGGER_PROBE_MISS,         /* Lost consecutive probes */
    TRIGGER_LINK_DOWN,          /* Interface went down */
    TRIGGER_RSRP_DROP,          /* LTE signal degraded */
    TRIGGER_SINR_DROP,          /* LTE SNR degraded */
    TRIGGER_STARLINK_OBSTR,     /* Starlink obstruction detected */
    TRIGGER_PREDICTED,          /* Prediction engine warned us */
    TRIGGER_MANUAL              /* Operator forced via UI */
} trigger_t;

static const char* TRIGGER_NAMES[] = {
    "none", "rtt_step", "probe_miss", "link_down", "rsrp_drop",
    "sinr_drop", "starlink_obstruction", "predicted", "manual"
};

/*-----------------------------------------------------------------------------
 * Probe Result - Single RTT/loss measurement
 *---------------------------------------------------------------------------*/
typedef struct {
    double      rtt_ms;         /* Round-trip time in milliseconds */
    bool        success;        /* Did probe succeed? */
    int64_t     timestamp_us;   /* Microsecond timestamp */
} probe_t;

/*-----------------------------------------------------------------------------
 * Cellular Info - LTE signal metrics from ModemManager
 *---------------------------------------------------------------------------*/
typedef struct {
    double      rsrp;           /* Reference Signal Received Power (dBm), -140 to -44 */
    double      rsrq;           /* Reference Signal Received Quality (dB), -20 to -3 */
    double      sinr;           /* Signal to Interference+Noise (dB), -20 to +30 */
    double      rssi;           /* Received Signal Strength Indicator (dBm) */
    char        carrier[32];    /* Carrier name: "T-Mobile", "AT&T", etc */
    char        cell_id[24];    /* Cell tower ID */
    char        tac[16];        /* Tracking Area Code */
    char        band[16];       /* LTE band: "B66", "B14", etc */
    bool        connected;      /* Is modem connected? */
    int64_t     timestamp_us;   /* When this was measured */
} cellular_t;

/*-----------------------------------------------------------------------------
 * Starlink Info - From dish HTTP API at 192.168.100.1
 *---------------------------------------------------------------------------*/
typedef struct {
    bool        connected;      /* Can we reach the dish? */
    bool        online;         /* Is dish online and connected to satellites? */
    char        state[32];      /* "CONNECTED", "SEARCHING", "BOOTING", etc */
    double      latency_ms;     /* Pop ping latency from dish */
    double      drop_rate;      /* Packet drop rate 0.0-1.0 */
    double      downlink_mbps;  /* Current downlink throughput */
    double      uplink_mbps;    /* Current uplink throughput */
    bool        obstructed;     /* Currently obstructed? */
    double      obstruction_pct;/* Percent time obstructed */
    int         obstruction_eta;/* Seconds until next obstruction, -1 if unknown */
    bool        thermal_throttle;/* Hardware thermal limiting */
    bool        motors_stuck;   /* Hardware motor issue */
    int64_t     timestamp_us;
} starlink_t;

/*-----------------------------------------------------------------------------
 * Uplink - Complete state for one uplink path
 *---------------------------------------------------------------------------*/
typedef struct {
    /* Identity */
    char            name[32];       /* "cell_a", "sl_b", etc */
    char            interface[32];  /* "wwan0", "enp1s0", etc */
    char            netns[32];      /* "ns_cell_a", "ns_sl_a", etc */
    char            veth[32];       /* "veth_cell_a", etc */
    uplink_id_t     id;
    uplink_type_t   type;
    bool            enabled;        /* Is this uplink configured? */
    
    /* Current state */
    bool            available;      /* Is uplink currently usable? */
    bool            force_failed;   /* Operator forced fail - sticky until cleared */
    /* Chaos injection (demo mode) */
    double          chaos_rtt;      /* Injected RTT */
    double          chaos_jitter;   /* Injected jitter */
    double          chaos_loss;     /* Injected loss % */
    bool            is_active;      /* Is this the primary uplink? */
    
    /* Live metrics */
    double          rtt_ms;         /* Current RTT */
    double          rtt_baseline;   /* Baseline RTT (slow moving average) */
    double          loss_pct;       /* Recent loss percentage */
    double          jitter_ms;      /* RTT variance */
    int             consec_fail;    /* Consecutive probe failures */
    
    /* Type-specific data */
    cellular_t      cellular;       /* LTE metrics (if type == LTE) */
    starlink_t      starlink;       /* Starlink metrics (if type == STARLINK) */
    
    /* History ring buffer */
    probe_t         history[HISTORY_SIZE];
    int             history_idx;
    
    /* Prediction scores */
    double          risk_now;       /* Current risk 0.0-1.0 */
    double          risk_ahead;     /* Predicted risk 0.0-1.0 */
    double          confidence;     /* Prediction confidence 0.0-1.0 */
} uplink_t;

/*-----------------------------------------------------------------------------
 * GPS Data - From gpsd
 *---------------------------------------------------------------------------*/
typedef struct {
    double      latitude;
    double      longitude;
    double      altitude_m;
    double      speed_mps;      /* Meters per second */
    double      heading;        /* Degrees from north */
    bool        valid;
    int64_t     timestamp_us;
} gps_t;

/*-----------------------------------------------------------------------------
 * System Status - Overall state of the Guardian
 *---------------------------------------------------------------------------*/
typedef struct {
    /* Operating mode and state */
    op_mode_t       mode;
    sys_state_t     state;
    
    /* Trigger info */
    trigger_t       last_trigger;
    char            trigger_detail[128];
    
    /* Active paths */
    uplink_id_t     active_uplink;
    bool            force_locked;       /* Operator force — suppresses auto-switch */
    int             active_controller;  /* 0 = ctrl_a, 1 = ctrl_b */
    
    /* Duplication state */
    bool            dup_enabled;
    int64_t         dup_enabled_at_us;
    int64_t         dup_engaged_at_us;   /* When dup was confirmed engaged (after settle) */
    
    /* Timers */
    int64_t         protect_start_us;
    int64_t         switch_start_us;
    int64_t         last_clean_us;
    int             switches_this_window;
    
    /* Display values */
    int             hold_remaining_sec;
    int             clean_remaining_sec;
    bool            flap_suppressed;
    
    /* Prediction */
    double          global_risk;
    char            recommendation[16];  /* "NORMAL", "PREPARE", "PROTECT" */
    
    /* Run tracking */
    char            run_id[64];
} status_t;

/*-----------------------------------------------------------------------------
 * Configuration - Loaded from JSON
 *---------------------------------------------------------------------------*/
typedef struct {
    /* Paths */
    char        config_path[256];
    char        data_dir[256];
    char        log_path[256];
    
    /* Node identity */
    char        node_id[64];
    char        node_role[16];
    
    /* Tripwire thresholds */
    int         rtt_step_ms;
    int         rtt_window_ms;
    int         probe_miss_count;
    int         probe_miss_window_ms;
    double      rsrp_drop_db;
    double      sinr_drop_db;
    
    /* Switching parameters */
    int         preroll_ms;
    int         min_hold_sec;
    int         clean_exit_sec;
    
    /* Feature flags */
    bool        gps_enabled;
    bool        pcap_enabled;
    bool        opencellid_enabled;
    bool        osm_enabled;
    
    /* Sample rate */
    int         sample_rate_hz;
    
    /* C8000 control */
    char        c8000_host[128];
    char        c8000_user[32];
    char        c8000_pass[64];
    
    /* Remote targets (nullable) */
    char        voice_server[64];
    char        llm_server[64];
} config_t;

/*=============================================================================
 * GLOBAL STATE
 * 
 * These are the core global variables that track system state.
 * Protected by g_mutex for thread safety.
 *===========================================================================*/

static volatile sig_atomic_t    g_running = 1;      /* Main loop control */
static config_t                 g_config;           /* Configuration */
static uplink_t                 g_uplinks[MAX_UPLINKS]; /* All uplinks */
static status_t                 g_status;           /* Current status */
static gps_t                    g_gps;              /* GPS data */
static sqlite3*                 g_db = NULL;        /* Training database */
static FILE*                    g_logfile = NULL;   /* JSONL log */
static pthread_mutex_t          g_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Last command result (for status.json) */
static char g_last_cmd_id[64] = "";
static char g_last_cmd_result[32] = "";
static char g_last_cmd_detail[128] = "";

/*=============================================================================
 * FUNCTION DECLARATIONS (implemented below)
 *===========================================================================*/

/* Time utilities */
static int64_t now_us(void);
static int64_t now_ms(void);

/* Logging */
static void log_event(const char* type, const char* fmt, ...);
static void log_info(const char* msg);

/* Configuration */
static int config_load(const char* path);

/* Uplink monitoring */
static void uplinks_init(void);
static void uplink_poll(uplink_t* u);
static void cellular_poll(uplink_t* u);
static void starlink_poll(uplink_t* u);

/* GPS */
static void gps_poll(void);
static void chaos_read(void);

/* Tripwire (fast path) */
static trigger_t tripwire_check(uplink_t* active);
static void tripwire_fire(trigger_t reason, const char* detail);

/* Duplication control */
/* Forward declare VIP arrays (defined in execute_switch section) */
static const char* VIP_DEVS[];
static const char* VIP_GWS[];

static int dup_init(void);
static int dup_enable(const char* src_veth, const char* dst_veth);
static int dup_disable(void);

/* Switching (slow path) */
static void slowpath_arbitrate(void);
static uplink_id_t select_best_uplink(void);
static void execute_switch(uplink_id_t target);

/* Protection mode */
static void protection_tick(void);

/* Prediction */
static void prediction_tick(void);

/* C8000 control */
static int c8000_switch(int controller);

/* Status output */
static void status_write(void);

/* Command processing */
static void commands_process(void);

/* Signal handling */
static void signal_handler(int sig);

/*=============================================================================
 * TIME UTILITIES
 *===========================================================================*/

static int64_t now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000000 + tv.tv_usec;
}

static int64_t now_ms(void) {
    return now_us() / 1000;
}

/*=============================================================================
 * LOGGING
 * 
 * All logs are JSONL format for easy parsing and replay.
 * Each line is a complete JSON object with timestamp, run_id, event type, data.
 *===========================================================================*/

static void log_event(const char* type, const char* fmt, ...) {
    va_list args;
    char msg[1024];
    char timestamp[32];
    struct timeval tv;
    
    gettimeofday(&tv, NULL);
    struct tm* tm = localtime(&tv.tv_sec);
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S", tm);
    
    va_start(args, fmt);
    vsnprintf(msg, sizeof(msg), fmt, args);
    va_end(args);
    
    FILE* out = g_logfile ? g_logfile : stderr;
    fprintf(out, "{\"ts\":\"%s.%03ld\",\"run\":\"%s\",\"event\":\"%s\",\"data\":%s}\n",
            timestamp, tv.tv_usec / 1000, g_status.run_id, type, msg);
    fflush(out);
}

static void log_info(const char* msg) {
    log_event("info", "\"%s\"", msg);
}

/*=============================================================================
 * CONFIGURATION
 * 
 * Configuration is loaded from JSON file. We use a simple parser here
 * to avoid heavy dependencies. In production, consider using cJSON or jansson.
 *===========================================================================*/

/* Simple JSON string extraction (good enough for our config) */
static int json_get_string(const char* json, const char* key, char* out, size_t len) {
    char search[128];
    snprintf(search, sizeof(search), "\"%s\":\"", key);
    const char* p = strstr(json, search);
    if (!p) return -1;
    p += strlen(search);
    size_t i = 0;
    while (*p && *p != '"' && i < len - 1) out[i++] = *p++;
    out[i] = '\0';
    return 0;
}

static int json_get_int(const char* json, const char* key, int def) {
    char search[128];
    snprintf(search, sizeof(search), "\"%s\":", key);
    const char* p = strstr(json, search);
    if (!p) return def;
    p += strlen(search);
    while (*p == ' ') p++;
    return atoi(p);
}

static bool json_get_bool(const char* json, const char* key, bool def) {
    char search[128];
    snprintf(search, sizeof(search), "\"%s\":", key);
    const char* p = strstr(json, search);
    if (!p) return def;
    p += strlen(search);
    while (*p == ' ') p++;
    return (strncmp(p, "true", 4) == 0);
}

static int config_load(const char* path) {
    /* Read file */
    FILE* f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "Cannot open config: %s\n", path);
        return -1;
    }
    
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    char* json = malloc(size + 1);
    fread(json, 1, size, f);
    json[size] = '\0';
    fclose(f);
    
    /* Parse values */
    strncpy(g_config.config_path, path, sizeof(g_config.config_path));
    
    json_get_string(json, "id", g_config.node_id, sizeof(g_config.node_id));
    json_get_string(json, "role", g_config.node_role, sizeof(g_config.node_role));
    
    /* Tripwire thresholds */
    g_config.rtt_step_ms = json_get_int(json, "rtt_step_threshold_ms", DEFAULT_RTT_STEP_MS);
    g_config.rtt_window_ms = json_get_int(json, "rtt_step_window_ms", DEFAULT_RTT_WINDOW_MS);
    g_config.probe_miss_count = json_get_int(json, "probe_miss_count", DEFAULT_PROBE_MISS_COUNT);
    g_config.probe_miss_window_ms = json_get_int(json, "probe_miss_window_ms", DEFAULT_PROBE_MISS_WINDOW);
    g_config.rsrp_drop_db = json_get_int(json, "rsrp_drop_threshold_db", DEFAULT_RSRP_DROP_DB);
    g_config.sinr_drop_db = json_get_int(json, "sinr_drop_threshold_db", DEFAULT_SINR_DROP_DB);
    
    /* Switching */
    g_config.preroll_ms = json_get_int(json, "preroll_ms", DEFAULT_PREROLL_MS);
    g_config.min_hold_sec = json_get_int(json, "min_hold_sec", DEFAULT_MIN_HOLD_SEC);
    g_config.clean_exit_sec = json_get_int(json, "clean_exit_sec", DEFAULT_CLEAN_EXIT_SEC);
    
    /* Features */
    g_config.gps_enabled = json_get_bool(json, "gps_enabled", true);
    g_config.pcap_enabled = json_get_bool(json, "pcap_enabled", true);
    g_config.sample_rate_hz = json_get_int(json, "sample_rate_hz", 10);
    
    /* C8000 */
    json_get_string(json, "host", g_config.c8000_host, sizeof(g_config.c8000_host));
    json_get_string(json, "user", g_config.c8000_user, sizeof(g_config.c8000_user));
    json_get_string(json, "password", g_config.c8000_pass, sizeof(g_config.c8000_pass));
    
    /* Paths */
    strncpy(g_config.data_dir, "/var/lib/pathsteer", sizeof(g_config.data_dir));
    snprintf(g_config.log_path, sizeof(g_config.log_path), "%s/logs", g_config.data_dir);
    
    free(json);
    return 0;
}

/*=============================================================================
 * DUPLICATION CONTROL (FAST PATH)
 * 
 * Traffic duplication is implemented using tc mirred. The rules are installed
 * at boot but DISABLED (high preference number). Enabling is just a filter
 * preference change - no rule rebuilding required. This is critical for
 * achieving millisecond-level response time.
 * 
 * Architecture:
 *   - Source: br-lan (where client traffic arrives)
 *   - Dest: veth_* interfaces (into each namespace)
 *   - Active path: normal routing
 *   - Dup path: tc mirred copies packet to secondary veth
 *===========================================================================*/

static int dup_init(void) {
    /*
     * Initialize nftables duplication infrastructure in ns_vip.
     * Clean any stale dup_table from previous run.
     */
    log_info("Installing duplication infrastructure (nftables in ns_vip)");
    
    system("ip netns exec ns_vip nft delete table ip dup_table 2>/dev/null");
    
    log_event("dup_init", "{\"status\":\"ready\",\"method\":\"nftables_dup\"}");
    return 0;
}

static int dup_enable(const char* src_veth, const char* dst_veth) {
    /*
     * Enable duplication using nftables dup in ns_vip.
     * src_veth = active VIP dev (e.g. "vip_fb")
     * dst_veth = backup VIP dev (e.g. "vip_fa")
     *
     * Finds the backup gateway from VIP_GWS array.
     * Installs: oif <active> dup to <backup_gw> device <backup>
     */
    int64_t start = now_us();
    char cmd[1024];
    
    /* Find backup gateway from VIP_GWS */
    const char* backup_gw = NULL;
    for (int i = 0; i < UPLINK_COUNT; i++) {
        if (strcmp(VIP_DEVS[i], dst_veth) == 0) {
            backup_gw = VIP_GWS[i];
            break;
        }
    }
    if (!backup_gw) {
        log_event("dup_enable_fail", "{\"reason\":\"no_gw_for_%s\"}", dst_veth);
        return -1;
    }
    
    /* Install nftables dup rule in ns_vip */
    system("ip netns exec ns_vip nft delete table ip dup_table 2>/dev/null");
    system("ip netns exec ns_vip nft add table ip dup_table");
    system("ip netns exec ns_vip nft \"add chain ip dup_table postrouting"
           " { type filter hook postrouting priority 0 \\; }\"");
    snprintf(cmd, sizeof(cmd),
        "ip netns exec ns_vip nft add rule ip dup_table postrouting "
        "oif %s dup to %s device %s",
        src_veth, backup_gw, dst_veth);
    system(cmd);
    
    int64_t elapsed = now_us() - start;
    
    pthread_mutex_lock(&g_mutex);
    g_status.dup_enabled = true;
    g_status.dup_enabled_at_us = now_us();
    g_status.dup_engaged_at_us = 0;
    pthread_mutex_unlock(&g_mutex);
    
    log_event("dup_enable", "{\"src\":\"%s\",\"dst\":\"%s\",\"gw\":\"%s\",\"latency_us\":%ld}",
              src_veth, dst_veth, backup_gw, elapsed);
    
    return 0;
}

static int dup_disable(void) {
    /*
     * Disable duplication by removing nftables dup_table in ns_vip.
     */
    system("ip netns exec ns_vip nft delete table ip dup_table 2>/dev/null");
    
    pthread_mutex_lock(&g_mutex);
    g_status.dup_enabled = false;
    pthread_mutex_unlock(&g_mutex);
    
    log_event("dup_disable", "{\"status\":\"disabled\"}");
    return 0;
}

/*=============================================================================
 * TRIPWIRE (FAST PATH)
 * 
 * The tripwire is the fast-path detection mechanism. When ANY of these
 * conditions is met, we IMMEDIATELY enable duplication - no waiting,
 * no arbitration. Speed is critical here (milliseconds matter).
 * 
 * After duplication is enabled, the slow path arbitrates which path
 * to switch to. But duplication happens first.
 *===========================================================================*/

static trigger_t tripwire_check(uplink_t* active) {
    if (!active || !active->enabled || !active->available) {
        return TRIGGER_LINK_DOWN;
    }
    
    /*
     * Check 1: RTT Step
     * If RTT jumped significantly over baseline, something changed.
     */
    if (active->history_idx >= 5) {
        double recent_sum = 0;
        int count = 0;
        for (int i = 0; i < 3; i++) {
            int idx = (active->history_idx - 1 - i) % HISTORY_SIZE;
            if (active->history[idx].success) {
                recent_sum += active->history[idx].rtt_ms;
                count++;
            }
        }
        if (count > 0) {
            double recent_avg = recent_sum / count;
            double step = recent_avg - active->rtt_baseline;
            if (step >= g_config.rtt_step_ms) {
                return TRIGGER_RTT_STEP;
            }
        }
    }
    
    /*
     * Check 2: Probe Miss
     * Consecutive probe failures indicate path problems.
     */
    if (active->consec_fail >= g_config.probe_miss_count) {
        return TRIGGER_PROBE_MISS;
    }
    
    /*
     * Check 3: LTE Signal Drop (if LTE uplink)
     */
    if (active->type == UPLINK_TYPE_LTE && active->cellular.rsrp < -120) {
        return TRIGGER_RSRP_DROP;
    }
    
    /*
     * Check 4: Starlink Obstruction (if Starlink uplink)
     */
    if (active->type == UPLINK_TYPE_STARLINK) {
        if (active->starlink.obstructed) {
            return TRIGGER_STARLINK_OBSTR;
        }
        /* Also trigger if obstruction predicted within 5 seconds */
        if (active->starlink.obstruction_eta > 0 && active->starlink.obstruction_eta < 5) {
            return TRIGGER_STARLINK_OBSTR;
        }
    }
    
    return TRIGGER_NONE;
}

static void tripwire_fire(trigger_t reason, const char* detail) {
    /*
     * FAST PATH: Enable duplication IMMEDIATELY.
     * This is the critical path - must complete in milliseconds.
     */
    int64_t start = now_us();
    
    /* Find secondary uplink to duplicate to */
    uplink_id_t secondary = (g_status.active_uplink + 1) % UPLINK_COUNT;
    while (secondary != g_status.active_uplink) {
        if (g_uplinks[secondary].enabled && g_uplinks[secondary].available) {
            break;
        }
        secondary = (secondary + 1) % UPLINK_COUNT;
    }
    
    /* Enable duplication */
    if (secondary != g_status.active_uplink) {
        dup_enable(VIP_DEVS[g_status.active_uplink], VIP_DEVS[secondary]);
    }
    
    /* Update state */
    pthread_mutex_lock(&g_mutex);
    g_status.state = STATE_PROTECT;
    g_status.last_trigger = reason;
    snprintf(g_status.trigger_detail, sizeof(g_status.trigger_detail), "%s", detail ? detail : "");
    g_status.protect_start_us = now_us();
    g_status.switches_this_window = 0;
    g_status.last_clean_us = 0;
    g_status.flap_suppressed = false;
    pthread_mutex_unlock(&g_mutex);
    
    int64_t elapsed = now_us() - start;
    
    log_event("tripwire_fire", "{\"trigger\":\"%s\",\"detail\":\"%s\",\"latency_us\":%ld}",
              TRIGGER_NAMES[reason], detail ? detail : "", elapsed);
}

/*=============================================================================
 * SWITCHING (SLOW PATH)
 * 
 * After duplication is active, we arbitrate which path to switch to.
 * This is the "slow" path - we have time because duplication protects us.
 * 
 * Rules:
 * 1. Wait preroll period before switching (let things stabilize)
 * 2. Switch at most ONCE per protection window (no flapping)
 * 3. Stay in protection for min_hold time
 * 4. Exit only after clean_exit time with no issues
 *===========================================================================*/

static void slowpath_arbitrate(void) {
    int64_t now = now_us();
    int64_t elapsed_ms = (now - g_status.protect_start_us) / 1000;
    
    /* Duplication must be confirmed engaged before we switch.
     * After dup_enable(), wait DUP_SETTLE_MS for tc mirred to take effect. */
    if (g_status.dup_enabled && g_status.dup_engaged_at_us == 0) {
        int64_t dup_age_ms = (now - g_status.dup_enabled_at_us) / 1000;
        if (dup_age_ms >= DUP_SETTLE_MS) {
            g_status.dup_engaged_at_us = now;
            log_event("dup_engaged", "{\"settle_ms\":%ld}", dup_age_ms);
        } else {
            /* Still settling — do not proceed to switch */
            g_status.state = STATE_SWITCHING;
            return;
        }
    }
    
    /* Still in preroll? */
    if (elapsed_ms < g_config.preroll_ms) {
        g_status.state = STATE_SWITCHING;
        return;
    }
    
    /* Already switched this window? */
    if (g_status.switches_this_window >= 3) {
        g_status.flap_suppressed = true;
        return;
    }
    
    /* Select best uplink */
    uplink_id_t best = select_best_uplink();
    
    /* Execute switch if different from current */
    if (best != g_status.active_uplink) {
        execute_switch(best);
    }
    
    g_status.state = STATE_HOLDING;
}

static uplink_id_t select_best_uplink(void) {
    /* If operator force is active, stay on current uplink */
    if (g_status.force_locked) return g_status.active_uplink;
    /*
     * Score each available uplink and select the best.
     * Lower RTT, lower risk, lower loss = better score.
     */
    uplink_id_t best = g_status.active_uplink;
    double best_score = -9999;
    
    for (int i = 0; i < UPLINK_COUNT; i++) {
        uplink_t* u = &g_uplinks[i];
        if (!u->enabled || !u->available) continue;
        
        /* Base score: 100 - RTT */
        double score = 100.0 - u->rtt_ms;
        
        /* Penalty for risk */
        score -= u->risk_now * 50.0;
        
        /* Penalty for loss */
        score -= u->loss_pct * 10.0;
        
        /* Bonus for good Starlink state */
        if (u->type == UPLINK_TYPE_STARLINK && u->starlink.online && !u->starlink.obstructed) {
            score += 20.0;
        }
        
        /* Bonus for strong LTE signal */
        if (u->type == UPLINK_TYPE_LTE && u->cellular.rsrp > -90) {
            score += 15.0;
        }
        
        if (score > best_score) {
            best_score = score;
            best = i;
        }
    }
    
    return best;
}

/*-----------------------------------------------------------------------------
 * Routing table names per uplink (from /etc/iproute2/rt_tables)
 * cell_a → tmo_cA (111), cell_b → att_cA (120)
 * sl_a → sl_a (113), sl_b → sl_b (114)
 * fa → fa (115), fb → fb (116)
 *---------------------------------------------------------------------------*/
static const char* UPLINK_TABLES[] = {
    "tmo_cA", "att_cA", "sl_a", "sl_b", "fa", "fb"
};

#define SERVICE_PREFIX "104.204.136.48/28"
#define RULE_PRIORITY  "90"

/*-----------------------------------------------------------------------------
 * ns_vip routing: device and gateway per uplink for route switching
 * Daemon does: ip netns exec ns_vip ip route replace default via <GW> dev <DEV>
 *---------------------------------------------------------------------------*/
static const char* VIP_DEVS[] = {
    "vip_cell_a", "vip_cell_b", "vip_sl_a", "vip_sl_b", "vip_fa", "vip_fb"
};
static const char* VIP_GWS[] = {
    "10.201.10.18", "10.201.10.22", "10.201.10.10", "10.201.10.14", "10.201.10.2", "10.201.10.6"
};

static void execute_switch(uplink_id_t target) {
    uplink_id_t old = g_status.active_uplink;
    
    log_event("switch", "{\"from\":\"%s\",\"to\":\"%s\",\"vip_dev\":\"%s\",\"vip_gw\":\"%s\"}",
              UPLINK_NAMES[old], UPLINK_NAMES[target], VIP_DEVS[target], VIP_GWS[target]);
    
    /*
     * Actuate OS routing: replace default route in ns_vip.
     * This is the REAL switch — one route change moves all service traffic.
     */
    char cmd[512];
    
    /* Step 1: Switch route in ns_vip */
    snprintf(cmd, sizeof(cmd),
        "ip netns exec ns_vip ip route replace default via %s dev %s",
        VIP_GWS[target], VIP_DEVS[target]);
    
    int ret = system(cmd);
    
    /* Step 2: Verify actuation succeeded */
    char verify_cmd[512];
    snprintf(verify_cmd, sizeof(verify_cmd),
        "ip netns exec ns_vip ip route show default | grep -q 'via %s dev %s'",
        VIP_GWS[target], VIP_DEVS[target]);
    
    int verify = system(verify_cmd);
    
    if (verify != 0) {
        /* Actuation FAILED — do NOT update active_uplink */
        log_event("switch_fail", "{\"target\":\"%s\",\"vip_dev\":\"%s\",\"reason\":\"ns_vip_route_verify_failed\",\"ret\":%d}",
                  UPLINK_NAMES[target], VIP_DEVS[target], ret);
        return;
    }
    
    /* Step 3: Switch controller return route (async, don't block) */
    snprintf(cmd, sizeof(cmd),
        "/opt/pathsteer/scripts/controller-route-switch.sh %s &",
        UPLINK_NAMES[target]);
    system(cmd);
    
    /* Step 4: Actuation confirmed — update state */
    pthread_mutex_lock(&g_mutex);
    g_uplinks[old].is_active = false;
    g_uplinks[target].is_active = true;
    g_status.active_uplink = target;
    g_status.switches_this_window++;
    g_status.switch_start_us = now_us();
    pthread_mutex_unlock(&g_mutex);
    
    log_event("switch_ok", "{\"from\":\"%s\",\"to\":\"%s\",\"vip_dev\":\"%s\"}",
              UPLINK_NAMES[old], UPLINK_NAMES[target], VIP_DEVS[target]);
}
/*=============================================================================
 * PROTECTION MODE TICK
 * 
 * Called every loop iteration when in protection mode.
 * Manages hold timer and clean exit logic.
 *===========================================================================*/

static void protection_tick(void) {
    int64_t now = now_us();
    int64_t protect_elapsed_sec = (now - g_status.protect_start_us) / 1000000;
    
    /* Update countdown displays */
    g_status.hold_remaining_sec = g_config.min_hold_sec - protect_elapsed_sec;
    if (g_status.hold_remaining_sec < 0) g_status.hold_remaining_sec = 0;
    
    /* Is current path clean? */
    uplink_t* active = &g_uplinks[g_status.active_uplink];
    bool is_clean = (active->consec_fail == 0 && 
                     active->rtt_ms < active->rtt_baseline + 30 &&
                     active->loss_pct < 2.0);
    
    if (is_clean) {
        if (g_status.last_clean_us == 0) {
            g_status.last_clean_us = now;
        }
        int64_t clean_sec = (now - g_status.last_clean_us) / 1000000;
        g_status.clean_remaining_sec = g_config.clean_exit_sec - clean_sec;
        if (g_status.clean_remaining_sec < 0) g_status.clean_remaining_sec = 0;
        
        /* Exit if hold passed AND clean enough */
        if (protect_elapsed_sec >= g_config.min_hold_sec &&
            clean_sec >= g_config.clean_exit_sec) {
            
            /* Exit protection */
            if (g_status.mode != MODE_MIRROR) {
                dup_disable();
            }
            
            g_status.state = STATE_NORMAL;
            g_status.last_trigger = TRIGGER_NONE;
            
            log_event("protection_exit", "{\"duration_sec\":%ld,\"clean_sec\":%ld}",
                      protect_elapsed_sec, clean_sec);
        }
    } else {
        g_status.last_clean_us = 0;
        g_status.clean_remaining_sec = g_config.clean_exit_sec;
    }
}

/*=============================================================================
 * UPLINK POLLING
 *===========================================================================*/

static double probe_rtt(const char* netns, const char* target) {
    char cmd[256];
    char result[64];
    
    if (netns && strlen(netns) > 0) {
        snprintf(cmd, sizeof(cmd), 
            "ip netns exec %s ping -c1 -W1 %s 2>/dev/null | grep 'time=' | sed 's/.*time=\\([0-9.]*\\).*/\\1/'",
            netns, target);
    } else {
        snprintf(cmd, sizeof(cmd),
            "ping -c1 -W1 %s 2>/dev/null | grep 'time=' | sed 's/.*time=\\([0-9.]*\\).*/\\1/'",
            target);
    }
    
    FILE* fp = popen(cmd, "r");
    if (!fp) return -1.0;
    
    double rtt = -1.0;
    if (fgets(result, sizeof(result), fp)) {
        rtt = atof(result);
    }
    pclose(fp);
    return rtt;
}

/* Probe RTT through a specific interface */
static double probe_rtt_iface(const char* iface, const char* target) {
    char cmd[256];
    char result[64];
    
    snprintf(cmd, sizeof(cmd),
        "ping -c1 -W2 -I %s %s 2>/dev/null | grep 'time=' | sed 's/.*time=\\([0-9.]*\\).*/\\1/'",
        iface, target);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) return -1.0;
    
    double rtt = -1.0;
    if (fgets(result, sizeof(result), fp)) {
        rtt = atof(result);
    }
    pclose(fp);
    return rtt;
}

/* =============================================================================
 * CHAOS INJECTION READER
 * Reads /run/pathsteer/chaos.json and applies to uplink metrics for demos
 * =============================================================================*/
static void chaos_read(void) {
    FILE* fp = fopen("/run/pathsteer/chaos.json", "r");
    if (!fp) return;
    char buf[1024];
    size_t n = fread(buf, 1, sizeof(buf)-1, fp);
    buf[n] = 0;
    fclose(fp);
    
    /* Reset all chaos values first */
    for (int i = 0; i < UPLINK_COUNT; i++) {
        g_uplinks[i].chaos_rtt = 0;
        g_uplinks[i].chaos_jitter = 0;
        g_uplinks[i].chaos_loss = 0;
    }

    /* Parse simple JSON - look for each uplink by canonical name */
    const char* names[] = {"cell_a", "cell_b", "sl_a", "sl_b", "fa", "fb"};
    for (int i = 0; i < UPLINK_COUNT; i++) {
        char pattern[64];
        snprintf(pattern, sizeof(pattern), "\"%s\"", names[i]);
        char* p = strstr(buf, pattern);
        if (p) {
            char* rtt = strstr(p, "\"rtt\":");
            char* jitter = strstr(p, "\"jitter\":");
            char* loss = strstr(p, "\"loss\":");
            if (rtt) g_uplinks[i].chaos_rtt = atof(rtt + 6);
            if (jitter) g_uplinks[i].chaos_jitter = atof(jitter + 9);
            if (loss) g_uplinks[i].chaos_loss = atof(loss + 7);
        }
    }
}


static void uplink_poll(uplink_t* u) {
    if (!u->enabled) return;
    
    int64_t start = now_us();
    double rtt;
    if (u->type == UPLINK_TYPE_LTE) {
        /* Cellular: ping controller via raw modem interface (path-correct) */

        rtt = probe_rtt_iface(u->interface, "104.204.136.13");
    } else {
        rtt = probe_rtt(u->netns, "8.8.8.8");
    }
    
    /* Record in history */
    int idx = u->history_idx % HISTORY_SIZE;
    /* Apply chaos to history so tripwire sees it */
    u->history[idx].rtt_ms = rtt + u->chaos_rtt + (u->chaos_jitter * ((double)rand()/RAND_MAX - 0.5) * 2);
    u->history[idx].success = (rtt > 0);
    u->history[idx].timestamp_us = start;
    u->history_idx++;
    
    /* Update metrics */
    if (rtt > 0) {
        u->rtt_ms = rtt;
        /* Apply chaos injection */
        u->rtt_ms += u->chaos_rtt + (u->chaos_jitter * ((double)rand()/RAND_MAX - 0.5) * 2);
        if (!u->force_failed) u->available = true;
        u->consec_fail = 0;
        
        /* Update baseline (slow EMA) */
        if (u->rtt_baseline == 0) {
            u->rtt_baseline = rtt;
        } else {
            u->rtt_baseline = u->rtt_baseline * 0.95 + rtt * 0.05;
        }
    } else {
        u->consec_fail++;
        if (u->consec_fail > 5) {
            u->available = false;
        }
    }
    
    /* Calculate loss from history */
    int success = 0, total = 0;
    for (int i = 0; i < 20 && i < u->history_idx; i++) {
        int hi = (u->history_idx - 1 - i) % HISTORY_SIZE;
        total++;
        if (u->history[hi].success) success++;
    }
    if (total > 0) {
        u->loss_pct = 100.0 * (total - success) / total;
        u->loss_pct += u->chaos_loss; if (u->loss_pct > 100.0) u->loss_pct = 100.0;  /* Add chaos injection */
    }
    
    /* Poll type-specific data */
    if (u->type == UPLINK_TYPE_LTE) {
        cellular_poll(u);
    } else if (u->type == UPLINK_TYPE_STARLINK) {
        starlink_poll(u);
    }
}

/*=============================================================================
 * CELLULAR POLLING (using mmcli)
 *===========================================================================*/

static void cellular_poll(uplink_t* u) {
    static time_t last_poll_cell_a = 0;
    static time_t last_poll_cell_b = 0;
    time_t now = time(NULL);
    time_t* last_poll;
    
    /* Rate limit: poll every 1 second - safe with persistent CID */
    if (u->id == UPLINK_CELL_A) {
        last_poll = &last_poll_cell_a;
    } else {
        last_poll = &last_poll_cell_b;
    }
    
    if (now - *last_poll < 5) {
        return;  /* Too soon, skip */
    }
    *last_poll = now;
    
    char cmd[512], line[512];
    const char* name = (u->id == UPLINK_CELL_A) ? "cell_a" : "cell_b";
    int dev_num = (u->id == UPLINK_CELL_A) ? 0 : 1;
    
    /* Use persistent client script to avoid CID exhaustion */
    snprintf(cmd, sizeof(cmd),
        "/opt/pathsteer/scripts/cellular-monitor.sh poll %d %s 2>/dev/null",
        dev_num, name);
    FILE* fp = popen(cmd, "r");
    if (!fp) return;
    int in_rsrp = 0;
    while (fgets(line, sizeof(line), fp)) {
        /* SINR (8): '9.0 dB' */
        if (strstr(line, "SINR") && strstr(line, ":")) {
            char* q = strchr(line, 39);  /* single quote */
            if (q) u->cellular.sinr = atof(q + 1);
        }
        /* RSRP: header, next line has value */
        if (strstr(line, "RSRP:") && !strstr(line, "RSRQ")) {
            in_rsrp = 1;
            continue;
        }
        /* Network 'lte': '-116 dBm' */
        if (in_rsrp && strstr(line, "Network")) {
            char* p = strstr(line, "': '");
            if (p) u->cellular.rsrp = atof(p + 4);
            in_rsrp = 0;
        }
    }
    pclose(fp);
    u->cellular.timestamp_us = now_us();
}
/*=============================================================================
 * STARLINK POLLING (HTTP API)
 *===========================================================================*/

/* CURL write callback */
typedef struct { char* data; size_t size; } curl_buf_t;

static size_t curl_write_cb(void* ptr, size_t size, size_t nmemb, void* userp) {
    curl_buf_t* buf = (curl_buf_t*)userp;
    size_t total = size * nmemb;
    char* tmp = realloc(buf->data, buf->size + total + 1);
    if (!tmp) return 0;
    buf->data = tmp;
    memcpy(&buf->data[buf->size], ptr, total);
    buf->size += total;
    buf->data[buf->size] = '\0';
    return total;
}

static void starlink_poll(uplink_t* u) {
    char cmd[256];
    char buf[2048];
    
    /* Use gRPC script - ns_sl_a or ns_sl_b, dish IP */
    const char* ns = u->id == UPLINK_SL_A ? "ns_sl_a" : "ns_sl_b";
    const char* dish_ip = "192.168.100.1";  /* Same for both, accessed from different ns */
    
    snprintf(cmd, sizeof(cmd), 
        "/opt/pathsteer/scripts/starlink-stats.sh %s %s 2>/dev/null", ns, dish_ip);
    
    FILE* fp = popen(cmd, "r");
    if (!fp) {
        u->starlink.connected = false;
        return;
    }
    
    size_t total = 0;
    size_t n;
    while ((n = fread(buf + total, 1, sizeof(buf) - total - 1, fp)) > 0) {
        total += n;
    }
    buf[total] = '\0';
    pclose(fp);
    
    if (total == 0 || strstr(buf, "error")) {
        u->starlink.connected = false;
        return;
    }
    
    u->starlink.connected = true;
    
    /* Parse JSON output from script */
    char* p;
    if ((p = strstr(buf, "\"latency_ms\":")) != NULL) {
        u->starlink.latency_ms = atof(p + 13);
    }
    if ((p = strstr(buf, "\"obstruction\":")) != NULL) {
        double frac = atof(p + 14);
        u->starlink.obstructed = (frac > 0.10);
        u->starlink.obstruction_pct = frac * 100.0;
    }
    if ((p = strstr(buf, "\"snr_ok\":")) != NULL) {
        u->starlink.online = (strstr(p, "true") != NULL);
    }
    if ((p = strstr(buf, "\"downlink_bps\":")) != NULL) {
        u->starlink.downlink_mbps = atof(p + 15) / 1000000.0;
    }
    if ((p = strstr(buf, "\"uplink_bps\":")) != NULL) {
        u->starlink.uplink_mbps = atof(p + 13) / 1000000.0;
    }
    
    strcpy(u->starlink.state, u->starlink.online ? "CONNECTED" : "SEARCHING");
    u->starlink.timestamp_us = now_us();
}

static void gps_poll(void) {
    if (!g_config.gps_enabled) return;
    
    FILE* fp = fopen("/run/pathsteer/gps.json", "r");
    if (!fp) return;
    
    char buf[1024];
    if (fgets(buf, sizeof(buf), fp)) {
        char* lat = strstr(buf, "\"lat\":");
        char* lon = strstr(buf, "\"lon\":");
        char* spd = strstr(buf, "\"speed_mph\":");
        char* fix = strstr(buf, "\"fix\": true");
        
        if (lat) g_gps.latitude = atof(lat + 6);
        if (lon) g_gps.longitude = atof(lon + 6);
        if (spd) g_gps.speed_mps = atof(spd + 13) / 2.237;
        g_gps.valid = (fix != NULL && lat && lon);
        g_gps.timestamp_us = now_us();
    }
    fclose(fp);
}

/*=============================================================================
 * PREDICTION ENGINE
 *===========================================================================*/

static void prediction_tick(void) {
    double max_risk = 0;
    
    for (int i = 0; i < UPLINK_COUNT; i++) {
        uplink_t* u = &g_uplinks[i];
        if (!u->enabled) continue;
        
        /* Calculate risk_now based on current metrics */
        u->risk_now = 0;
        
        if (u->rtt_ms > u->rtt_baseline * 1.5) u->risk_now += 0.3;
        if (u->loss_pct > 50) u->risk_now += 0.5; else if (u->loss_pct > 20) u->risk_now += 0.4; else if (u->loss_pct > 5) u->risk_now += 0.3;
        if (u->consec_fail > 0) u->risk_now += 0.2 * (u->consec_fail > 5 ? 5 : u->consec_fail);
        
        if (u->type == UPLINK_TYPE_STARLINK) {
            u->risk_now += u->starlink.obstruction_pct * 0.01;  /* 10% obstruction = 0.1 risk */
        }
        
        if (u->type == UPLINK_TYPE_LTE && u->cellular.rsrp < -110) {
            u->risk_now += 0.4;
        }
        
        if (u->risk_now > 1.0) u->risk_now = 1.0; // Capped
        
        
        if (u->is_active && u->risk_now > max_risk) {
            max_risk = u->risk_now;
        }
    }
    
    g_status.global_risk = max_risk;
    
    if (max_risk >= 0.7) {
        strcpy(g_status.recommendation, "PROTECT");
    } else if (max_risk >= 0.4) {
        strcpy(g_status.recommendation, "PREPARE");
    } else {
        strcpy(g_status.recommendation, "NORMAL");
    }
}

/*=============================================================================
 * STATUS OUTPUT
 * 
 * Write current status to JSON file for Web UI consumption.
 * Updated at 10 Hz.
 *===========================================================================*/

static void status_write(void) {
    FILE* fp = fopen("/run/pathsteer/status.json.tmp", "w");
    if (!fp) return;
    
    pthread_mutex_lock(&g_mutex);
    
    /* Convert speed to mph for display */
    double speed_mph = g_gps.speed_mps * 2.237;
    
    fprintf(fp, "{\n");
    fprintf(fp, "  \"mode\": \"%s\",\n", MODE_NAMES[g_status.mode]);
    fprintf(fp, "  \"state\": \"%s\",\n", STATE_NAMES[g_status.state]);
    fprintf(fp, "  \"trigger\": \"%s\",\n", TRIGGER_NAMES[g_status.last_trigger]);
    fprintf(fp, "  \"trigger_detail\": \"%s\",\n", g_status.trigger_detail);
    fprintf(fp, "  \"active_uplink\": \"%s\",\n", UPLINK_NAMES[g_status.active_uplink]);
    fprintf(fp, "  \"active_controller\": %d,\n", g_status.active_controller);
    fprintf(fp, "  \"dup_enabled\": %s,\n", g_status.dup_enabled ? "true" : "false");
    fprintf(fp, "  \"hold_remaining\": %d,\n", g_status.hold_remaining_sec);
    fprintf(fp, "  \"clean_remaining\": %d,\n", g_status.clean_remaining_sec);
    fprintf(fp, "  \"switches_this_window\": %d,\n", g_status.switches_this_window);
    fprintf(fp, "  \"flap_suppressed\": %s,\n", g_status.flap_suppressed ? "true" : "false");
    fprintf(fp, "  \"global_risk\": %.2f,\n", g_status.global_risk);
    fprintf(fp, "  \"recommendation\": \"%s\",\n", g_status.recommendation);
    fprintf(fp, "  \"run_id\": \"%s\",\n", g_status.run_id);
    fprintf(fp, "  \"last_cmd\": {\"id\": \"%s\", \"result\": \"%s\", \"detail\": \"%s\"},\n",
            g_last_cmd_id, g_last_cmd_result, g_last_cmd_detail);
    
    /* GPS */
    fprintf(fp, "  \"gps\": {\"valid\": %s, \"lat\": %.6f, \"lon\": %.6f, \"speed_mph\": %.1f, \"heading\": %.1f},\n",
            g_gps.valid ? "true" : "false", g_gps.latitude, g_gps.longitude, speed_mph, g_gps.heading);
    
    /* Uplinks */
    fprintf(fp, "  \"uplinks\": [\n");
    for (int i = 0; i < UPLINK_COUNT; i++) {
        uplink_t* u = &g_uplinks[i];
        fprintf(fp, "    {\"name\": \"%s\", \"enabled\": %s, \"available\": %s, \"active\": %s,\n",
                u->name, u->enabled ? "true" : "false", 
                u->available ? "true" : "false", u->is_active ? "true" : "false");
        fprintf(fp, "     \"rtt_ms\": %.1f, \"rtt_baseline\": %.1f, \"loss_pct\": %.1f,\n",
                u->rtt_ms, u->rtt_baseline, u->loss_pct);
        fprintf(fp, "     \"risk_now\": %.2f, \"consec_fail\": %d", u->risk_now, u->consec_fail);
        
        if (u->type == UPLINK_TYPE_LTE) {
            fprintf(fp, ",\n     \"cellular\": {\"rsrp\": %.1f, \"sinr\": %.1f, \"carrier\": \"%s\"}",
                    u->cellular.rsrp, u->cellular.sinr, u->cellular.carrier);
        }
        if (u->type == UPLINK_TYPE_STARLINK) {
            fprintf(fp, ",\n     \"starlink\": {\"state\": \"%s\", \"latency\": %.1f, \"obstructed\": %s, \"obstruction_pct\": %.2f, \"eta\": %d}",
                    u->starlink.state, u->starlink.latency_ms, 
                    u->starlink.obstructed ? "true" : "false", u->starlink.obstruction_pct, u->starlink.obstruction_eta);
        }
        fprintf(fp, "}%s\n", i < UPLINK_COUNT - 1 ? "," : "");
    }
    fprintf(fp, "  ]\n");
    fprintf(fp, "}\n");
    
    pthread_mutex_unlock(&g_mutex);
    fflush(fp);
    fsync(fileno(fp));
    fclose(fp);
    rename("/run/pathsteer/status.json.tmp", "/run/pathsteer/status.json");
}

/*=============================================================================
 * COMMAND PROCESSING
 * 
 * Primary: scan /run/pathsteer/cmdq/ directory (FIFO by filename).
 * Fallback: single /run/pathsteer/command file (legacy, optional).
 * Each command results in ack/exec/fail reflected in status.
 *===========================================================================*/

/* Result of last command, written into status.json (globals declared above) */

static void process_one_command(const char* cmd, const char* cmd_id) {
    strncpy(g_last_cmd_id, cmd_id, sizeof(g_last_cmd_id) - 1);
    g_last_cmd_id[sizeof(g_last_cmd_id) - 1] = '\0';
    
    if (strncmp(cmd, "mode:", 5) == 0) {
            const char* mode = cmd + 5;
            if (strcmp(mode, "training") == 0) {
                g_status.mode = MODE_TRAINING;
                dup_disable();
            } else if (strcmp(mode, "tripwire") == 0) {
                g_status.mode = MODE_TRIPWIRE;
            } else if (strcmp(mode, "mirror") == 0) {
                g_status.mode = MODE_MIRROR;
                dup_enable("br-lan", g_uplinks[1].veth);  /* Always dup in mirror */
            }
            log_event("mode_change", "{\"mode\":\"%s\"}", MODE_NAMES[g_status.mode]);
            strcpy(g_last_cmd_result, "exec");
            snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "mode=%s", MODE_NAMES[g_status.mode]);
            
        } else if (strncmp(cmd, "force:", 6) == 0) {
            const char* uplink = cmd + 6;
            /* force:auto clears the lock and resets flap suppressor */
            if (strcmp(uplink, "auto") == 0) {
                g_status.force_locked = false;
                g_status.switches_this_window = 0;
                g_status.state = STATE_NORMAL;
                /* Immediate re-evaluation: pick best uplink now */
                {
                    uplink_id_t best = select_best_uplink();
                    if (best != g_status.active_uplink) {
                        execute_switch(best);
                    }
                }
                strcpy(g_last_cmd_result, "exec");
                snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "force=auto");
            } else {
            bool found = false;
            for (int i = 0; i < UPLINK_COUNT; i++) {
                if (strcmp(UPLINK_NAMES[i], uplink) == 0) {
                    g_uplinks[i].force_failed = false;  /* Clear any force_fail */
                    g_uplinks[i].available = true;
                    execute_switch(i);
                    found = true;
                    g_status.force_locked = true;
                    break;
                }
            }
            strcpy(g_last_cmd_result, found ? "exec" : "fail");
            snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "force=%s", uplink);
            } /* end else (not auto) */
            
        } else if (strcmp(cmd, "trigger") == 0) {
            tripwire_fire(TRIGGER_MANUAL, "operator");
            strcpy(g_last_cmd_result, "exec");
            strcpy(g_last_cmd_detail, "manual_trigger");
            
        } else if (strncmp(cmd, "c8000:", 6) == 0) {
            int ctrl = atoi(cmd + 6);
            c8000_switch(ctrl);
            strcpy(g_last_cmd_result, "exec");
            snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "c8000=%d", ctrl);

        } else if (strncmp(cmd, "enable:", 7) == 0) {
            const char* uplink = cmd + 7;
            bool found = false;
            for (int i = 0; i < UPLINK_COUNT; i++) {
                if (strcmp(UPLINK_NAMES[i], uplink) == 0) {
                    g_uplinks[i].enabled = true;
                    log_event("uplink_enabled", "{\"uplink\":\"%s\"}", uplink);
                    found = true;
                    break;
                }
            }
            strcpy(g_last_cmd_result, found ? "exec" : "fail");
            snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "enable=%s", uplink);

        } else if (strncmp(cmd, "disable:", 8) == 0) {
            const char* uplink = cmd + 8;
            bool found = false;
            for (int i = 0; i < UPLINK_COUNT; i++) {
                if (strcmp(UPLINK_NAMES[i], uplink) == 0) {
                    g_uplinks[i].enabled = false;
                    log_event("uplink_disabled", "{\"uplink\":\"%s\"}", uplink);
                    found = true;
                    break;
                }
            }
            strcpy(g_last_cmd_result, found ? "exec" : "fail");
            snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "disable=%s", uplink);

        } else if (strncmp(cmd, "fail:", 5) == 0) {
            const char* uplink = cmd + 5;
            bool found = false;
            for (int i = 0; i < UPLINK_COUNT; i++) {
                if (strcmp(UPLINK_NAMES[i], uplink) == 0) {
                    g_uplinks[i].available = false;
                    g_uplinks[i].force_failed = true;
                    g_uplinks[i].consec_fail = 10;
                    log_event("uplink_force_fail", "{\"uplink\":\"%s\"}", uplink);
                    found = true;
                    break;
                }
            }
            strcpy(g_last_cmd_result, found ? "exec" : "fail");
            snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "fail=%s", uplink);

        } else if (strncmp(cmd, "unfail:", 7) == 0) {
            const char* uplink = cmd + 7;
            bool found = false;
            for (int i = 0; i < UPLINK_COUNT; i++) {
                if (strcmp(UPLINK_NAMES[i], uplink) == 0) {
                    g_uplinks[i].force_failed = false;
                    g_uplinks[i].available = true;
                    g_uplinks[i].consec_fail = 0;
                    log_event("uplink_unfail", "{\"uplink\":\"%s\"}", uplink);
                    found = true;
                    break;
                }
            }
            strcpy(g_last_cmd_result, found ? "exec" : "fail");
            snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "unfail=%s", uplink);
        } else {
            strcpy(g_last_cmd_result, "fail");
            snprintf(g_last_cmd_detail, sizeof(g_last_cmd_detail), "unknown_cmd");
        }
    
    log_event("cmd_result", "{\"id\":\"%s\",\"result\":\"%s\",\"detail\":\"%s\"}",
              g_last_cmd_id, g_last_cmd_result, g_last_cmd_detail);
}

static void commands_process(void) {
    /*
     * Primary: process /run/pathsteer/cmdq/ directory (FIFO by filename).
     * Files are named <timestamp>-<cmd_id>.cmd for ordering.
     */
    DIR* dir = opendir("/run/pathsteer/cmdq");
    if (dir) {
        /* Collect filenames and sort for FIFO */
        char filenames[64][256];
        int count = 0;
        struct dirent* entry;
        while ((entry = readdir(dir)) != NULL && count < 64) {
            if (entry->d_name[0] == '.') continue;
            size_t len = strlen(entry->d_name);
            if (len < 5 || strcmp(entry->d_name + len - 4, ".cmd") != 0) continue;
            snprintf(filenames[count], sizeof(filenames[count]), "%s", entry->d_name);
            count++;
        }
        closedir(dir);
        
        /* Sort by filename (timestamp prefix gives FIFO order) */
        for (int i = 0; i < count - 1; i++) {
            for (int j = i + 1; j < count; j++) {
                if (strcmp(filenames[i], filenames[j]) > 0) {
                    char tmp[256];
                    strcpy(tmp, filenames[i]);
                    strcpy(filenames[i], filenames[j]);
                    strcpy(filenames[j], tmp);
                }
            }
        }
        
        /* Process each command file */
        for (int i = 0; i < count; i++) {
            char path[512];
            snprintf(path, sizeof(path), "/run/pathsteer/cmdq/%s", filenames[i]);
            FILE* fp = fopen(path, "r");
            if (!fp) continue;
            char cmd[256];
            if (fgets(cmd, sizeof(cmd), fp)) {
                cmd[strcspn(cmd, "\n")] = 0;
                process_one_command(cmd, filenames[i]);
            }
            fclose(fp);
            unlink(path);  /* Delete processed file */
        }
    }
    
    /*
     * Legacy fallback: single /run/pathsteer/command file.
     */
    FILE* fp = fopen("/run/pathsteer/command", "r");
    if (!fp) return;
    
    char cmd[256];
    if (fgets(cmd, sizeof(cmd), fp)) {
        cmd[strcspn(cmd, "\n")] = 0;
        process_one_command(cmd, "legacy");
    }
    
    fclose(fp);
    unlink("/run/pathsteer/command");
}

/*=============================================================================
 * C8000 CONTROL
 *===========================================================================*/

static int c8000_switch(int controller) {
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "%s/scripts/c8000-switch.sh ctrl_%c",
             "/opt/pathsteer", controller == 0 ? 'a' : 'b');
    
    log_event("c8000_switch", "{\"controller\":%d}", controller);
    
    int ret = system(cmd);
    if (ret == 0) {
        g_status.active_controller = controller;
    }
    return ret;
}

/*=============================================================================
 * SIGNAL HANDLING
 *===========================================================================*/

static void signal_handler(int sig) {
    if (sig == SIGINT || sig == SIGTERM) {
        g_running = 0;
    }
}

/*=============================================================================
 * UPLINK INITIALIZATION
 *===========================================================================*/

static void uplinks_init(void) {
    memset(g_uplinks, 0, sizeof(g_uplinks));
    
    /* Cell A - T-Mobile */
    g_uplinks[UPLINK_CELL_A].id = UPLINK_CELL_A;
    g_uplinks[UPLINK_CELL_A].type = UPLINK_TYPE_LTE;
    strcpy(g_uplinks[UPLINK_CELL_A].name, "cell_a");
    strcpy(g_uplinks[UPLINK_CELL_A].interface, "wwan0");
    strcpy(g_uplinks[UPLINK_CELL_A].netns, "ns_cell_a");
    strcpy(g_uplinks[UPLINK_CELL_A].veth, "veth_cell_a");
    strcpy(g_uplinks[UPLINK_CELL_A].cellular.carrier, "T-Mobile");
    g_uplinks[UPLINK_CELL_A].enabled = true;
    g_uplinks[UPLINK_CELL_A].is_active = true;  /* Default active */
    
    /* Cell B - AT&T */
    g_uplinks[UPLINK_CELL_B].id = UPLINK_CELL_B;
    g_uplinks[UPLINK_CELL_B].type = UPLINK_TYPE_LTE;
    strcpy(g_uplinks[UPLINK_CELL_B].name, "cell_b");
    strcpy(g_uplinks[UPLINK_CELL_B].interface, "wwan1");
    strcpy(g_uplinks[UPLINK_CELL_B].netns, "ns_cell_b");
    strcpy(g_uplinks[UPLINK_CELL_B].veth, "veth_cell_b");
    strcpy(g_uplinks[UPLINK_CELL_B].cellular.carrier, "AT&T");
    g_uplinks[UPLINK_CELL_B].enabled = true;
    
    /* Starlink A - Roof */
    g_uplinks[UPLINK_SL_A].id = UPLINK_SL_A;
    g_uplinks[UPLINK_SL_A].type = UPLINK_TYPE_STARLINK;
    strcpy(g_uplinks[UPLINK_SL_A].name, "sl_a");
    strcpy(g_uplinks[UPLINK_SL_A].interface, "enp3s0");
    strcpy(g_uplinks[UPLINK_SL_A].netns, "ns_sl_a");
    strcpy(g_uplinks[UPLINK_SL_A].veth, "veth_sl_a");
    g_uplinks[UPLINK_SL_A].enabled = true;
    
    /* Starlink B - Rear */
    g_uplinks[UPLINK_SL_B].id = UPLINK_SL_B;
    g_uplinks[UPLINK_SL_B].type = UPLINK_TYPE_STARLINK;
    strcpy(g_uplinks[UPLINK_SL_B].name, "sl_b");
    strcpy(g_uplinks[UPLINK_SL_B].interface, "enp4s0");
    strcpy(g_uplinks[UPLINK_SL_B].netns, "ns_sl_b");
    strcpy(g_uplinks[UPLINK_SL_B].veth, "veth_sl_b");
    g_uplinks[UPLINK_SL_B].enabled = true;
    
    /* Fiber A - Google */
    g_uplinks[UPLINK_FIBER1].id = UPLINK_FIBER1;
    g_uplinks[UPLINK_FIBER1].type = UPLINK_TYPE_FIBER;
    strcpy(g_uplinks[UPLINK_FIBER1].name, "fa");
    strcpy(g_uplinks[UPLINK_FIBER1].interface, "enp1s0");
    strcpy(g_uplinks[UPLINK_FIBER1].netns, "ns_fa");
    strcpy(g_uplinks[UPLINK_FIBER1].veth, "veth_fa");
    g_uplinks[UPLINK_FIBER1].enabled = true;

    /* Fiber B - ATT */
    g_uplinks[UPLINK_FIBER2].id = UPLINK_FIBER2;
    g_uplinks[UPLINK_FIBER2].type = UPLINK_TYPE_FIBER;
    strcpy(g_uplinks[UPLINK_FIBER2].name, "fb");
    strcpy(g_uplinks[UPLINK_FIBER2].interface, "enp2s0");
    strcpy(g_uplinks[UPLINK_FIBER2].netns, "ns_fb");
    strcpy(g_uplinks[UPLINK_FIBER2].veth, "veth_fb");
    g_uplinks[UPLINK_FIBER2].enabled = true;

    g_status.active_uplink = UPLINK_CELL_A;
}

/*=============================================================================
 * MAIN
 *===========================================================================*/

int main(int argc, char** argv) {
    const char* config_path = "/etc/pathsteer/config.json";
    
    /* Parse args */
    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "--config") == 0 || strcmp(argv[i], "-c") == 0) && i + 1 < argc) {
            config_path = argv[++i];
        }
    }
    
    /* Setup */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN);
    
    mkdir("/run/pathsteer", 0755);
    mkdir("/run/pathsteer/cmdq", 0755);
    mkdir("/var/lib/pathsteer", 0755);
    mkdir("/var/lib/pathsteer/logs", 0755);
    
    /* Generate run ID */
    time_t now = time(NULL);
    strftime(g_status.run_id, sizeof(g_status.run_id), "%Y%m%d_%H%M%S", localtime(&now));
    
    /* Load config */
    config_load(config_path);
    
    /* Open log */
    char logfile[512];
    snprintf(logfile, sizeof(logfile), "%s/pathsteer_%s.jsonl", g_config.log_path, g_status.run_id);
    g_logfile = fopen(logfile, "a");
    
    /* Initialize */
    uplinks_init();
    
    /* Load enabled states from config file */
    {
        FILE* cf = fopen(config_path, "r");
        if (cf) {
            fseek(cf, 0, SEEK_END);
            long size = ftell(cf);
            fseek(cf, 0, SEEK_SET);
            char* json = malloc(size + 1);
            fread(json, 1, size, cf);
            json[size] = 0;
            fclose(cf);
            
            const char* uplink_names[] = {"cell_a", "cell_b", "sl_a", "sl_b", "fa", "fb"};
            for (int i = 0; i < 6; i++) {
                char search[128];
                snprintf(search, sizeof(search), "\"%s\"", uplink_names[i]);
                char* pos = strstr(json, search);
                if (pos) {
                    char* enabled = strstr(pos, "\"enabled\"");
                    if (enabled && enabled < pos + 200) {
                        if (strstr(enabled, "false") && strstr(enabled, "false") < enabled + 30) {
                            g_uplinks[i].enabled = false;
                            printf("Config: %s disabled\n", uplink_names[i]);
                        }
                    }
                }
            }
            free(json);
        }
    }
    
    dup_init();
    curl_global_init(CURL_GLOBAL_DEFAULT);
    
    /* Set initial mode */
    g_status.mode = MODE_TRIPWIRE;
    g_status.state = STATE_NORMAL;
    strcpy(g_status.recommendation, "NORMAL");
    
    /* Install initial ns_vip route for default active uplink */
    {
        char cmd[256];
        snprintf(cmd, sizeof(cmd),
            "ip netns exec ns_vip ip route replace default via %s dev %s",
            VIP_GWS[g_status.active_uplink], VIP_DEVS[g_status.active_uplink]);
        system(cmd);
        log_event("init_route", "{\"vip_dev\":\"%s\",\"vip_gw\":\"%s\"}",
                  VIP_DEVS[g_status.active_uplink], VIP_GWS[g_status.active_uplink]);
    }
    log_event("startup", "{\"version\":\"%s\",\"run_id\":\"%s\",\"config\":\"%s\"}",
              VERSION, g_status.run_id, config_path);
    
    /* Main loop */
    int64_t last_probe = 0;
    int64_t last_gps = 0;
    int64_t last_predict = 0;
    int64_t last_status = 0;
    int probe_interval = 1000000 / g_config.sample_rate_hz;
    
    while (g_running) {
        int64_t now_t = now_us();
        
        /* Probe uplinks */
        if (now_t - last_probe >= probe_interval) {
            chaos_read();  /* Read chaos injection values once per cycle */
            for (int i = 0; i < UPLINK_COUNT; i++) {
                uplink_poll(&g_uplinks[i]);
            }
            last_probe = now_t;
        }
        
        /* GPS (1 Hz) */
        if (now_t - last_gps >= 1000000) {
            gps_poll();
            last_gps = now_t;
        }
        
        /* Prediction (4 Hz) */
        if (now_t - last_predict >= RISK_INTERVAL_MS * 1000) {
            prediction_tick();
            last_predict = now_t;
        }
        
        /* State machine */
        if (g_status.mode != MODE_TRAINING) {
            switch (g_status.state) {
                case STATE_NORMAL:
                case STATE_PREPARE: {
                    uplink_t* active = &g_uplinks[g_status.active_uplink];
                    trigger_t t = tripwire_check(active);
                    if (t != TRIGGER_NONE) {
                        tripwire_fire(t, TRIGGER_NAMES[t]);
                    }
                    break;
                }
                case STATE_PROTECT:
                    slowpath_arbitrate();
                    /* fall through */
                case STATE_SWITCHING:
                case STATE_HOLDING:
                    protection_tick();
                    break;
            }
        }
        
        /* Commands */
        commands_process();
        
        /* Status output (10 Hz) */
        if (now_t - last_status >= STATUS_INTERVAL_MS * 1000) {
            status_write();
            last_status = now_t;
        }
        
        usleep(10000);  /* 10ms sleep */
    }
    
    /* Shutdown */
    log_event("shutdown", "{\"run_id\":\"%s\"}", g_status.run_id);
    
    dup_disable();
    curl_global_cleanup();
    if (g_logfile) fclose(g_logfile);
    
    return 0;
}