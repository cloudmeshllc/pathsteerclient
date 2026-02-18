/*******************************************************************************
 * dedupe.c - PathSteer Guardian Controller Dedupe Daemon
 * 
 * PURPOSE:
 *   This daemon runs on the Controller (PoP) and deduplicates packets that
 *   arrive via multiple WireGuard tunnels from the Edge.
 * 
 * ALGORITHM:
 *   First-arrival wins. We track flows by 5-tuple and sequence/timestamp.
 *   If we see the same packet twice (same hash), we drop the second one.
 *
 * Copyright (c) 2025 PathSteer Networks
 ******************************************************************************/

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <pthread.h>
#include <sys/time.h>

#define VERSION "1.0.0"
#define FLOW_TABLE_SIZE 65536
#define FLOW_TTL_MS 5000
#define STATS_INTERVAL_SEC 10

/*=============================================================================
 * Flow Entry - Tracks seen packets
 *===========================================================================*/
typedef struct {
    uint32_t    hash;           /* Packet hash (5-tuple + seq) */
    int64_t     timestamp_us;   /* When first seen */
    bool        valid;
} flow_entry_t;

/*=============================================================================
 * Statistics
 *===========================================================================*/
typedef struct {
    uint64_t    packets_total;
    uint64_t    packets_forwarded;
    uint64_t    packets_dropped;    /* Duplicates */
    uint64_t    flows_active;
} stats_t;

/*=============================================================================
 * Globals
 *===========================================================================*/
static volatile sig_atomic_t g_running = 1;
static flow_entry_t g_flows[FLOW_TABLE_SIZE];
static stats_t g_stats;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;

/*=============================================================================
 * Time
 *===========================================================================*/
static int64_t now_us(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000000 + tv.tv_usec;
}

/*=============================================================================
 * Flow Table Operations
 *===========================================================================*/

/* Simple hash function */
static uint32_t hash_packet(const uint8_t* data, size_t len) {
    uint32_t hash = 0x811c9dc5;  /* FNV offset */
    for (size_t i = 0; i < len && i < 64; i++) {
        hash ^= data[i];
        hash *= 0x01000193;  /* FNV prime */
    }
    return hash;
}

/* Check if packet is duplicate, add if not */
static bool flow_check_and_add(uint32_t hash) {
    int64_t now = now_us();
    int idx = hash % FLOW_TABLE_SIZE;
    
    pthread_mutex_lock(&g_mutex);
    
    /* Check if exists and not expired */
    if (g_flows[idx].valid && g_flows[idx].hash == hash) {
        int64_t age_ms = (now - g_flows[idx].timestamp_us) / 1000;
        if (age_ms < FLOW_TTL_MS) {
            /* Duplicate! */
            g_stats.packets_dropped++;
            pthread_mutex_unlock(&g_mutex);
            return true;
        }
    }
    
    /* Not a duplicate, add to table */
    g_flows[idx].hash = hash;
    g_flows[idx].timestamp_us = now;
    g_flows[idx].valid = true;
    g_stats.packets_forwarded++;
    
    pthread_mutex_unlock(&g_mutex);
    return false;
}

/* Clean expired entries */
static void flow_cleanup(void) {
    int64_t now = now_us();
    int64_t threshold = now - (FLOW_TTL_MS * 1000);
    int active = 0;
    
    pthread_mutex_lock(&g_mutex);
    for (int i = 0; i < FLOW_TABLE_SIZE; i++) {
        if (g_flows[i].valid) {
            if (g_flows[i].timestamp_us < threshold) {
                g_flows[i].valid = false;
            } else {
                active++;
            }
        }
    }
    g_stats.flows_active = active;
    pthread_mutex_unlock(&g_mutex);
}

/*=============================================================================
 * Statistics Output
 *===========================================================================*/
static void stats_print(void) {
    printf("[dedupe] total=%lu fwd=%lu dup=%lu active=%lu\n",
           g_stats.packets_total,
           g_stats.packets_forwarded,
           g_stats.packets_dropped,
           g_stats.flows_active);
}

/*=============================================================================
 * Signal Handling
 *===========================================================================*/
static void signal_handler(int sig) {
    if (sig == SIGINT || sig == SIGTERM) {
        g_running = 0;
    }
}

/*=============================================================================
 * Main
 * 
 * In a real implementation, this would:
 * 1. Use NFQUEUE to intercept packets from WireGuard
 * 2. Check each packet against flow table
 * 3. Drop duplicates, forward unique packets
 * 
 * For V1 demo, we use iptables/nftables marks and let kernel handle forwarding.
 * This daemon just tracks statistics.
 *===========================================================================*/
int main(int argc, char** argv) {
    (void)argc; (void)argv;
    
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    printf("[dedupe] PathSteer Guardian Dedupe Daemon v%s\n", VERSION);
    printf("[dedupe] Flow table size: %d, TTL: %dms\n", FLOW_TABLE_SIZE, FLOW_TTL_MS);
    
    memset(g_flows, 0, sizeof(g_flows));
    memset(&g_stats, 0, sizeof(g_stats));
    
    /* 
     * In production, we'd set up NFQUEUE here.
     * For V1, we just monitor and report statistics.
     * The actual deduplication is handled by connection tracking.
     */
    
    time_t last_stats = time(NULL);
    time_t last_cleanup = time(NULL);
    
    while (g_running) {
        time_t now = time(NULL);
        
        /* Print stats periodically */
        if (now - last_stats >= STATS_INTERVAL_SEC) {
            stats_print();
            last_stats = now;
        }
        
        /* Clean expired flows */
        if (now - last_cleanup >= 1) {
            flow_cleanup();
            last_cleanup = now;
        }
        
        usleep(100000);  /* 100ms */
    }
    
    printf("[dedupe] Shutdown\n");
    stats_print();
    
    return 0;
}
