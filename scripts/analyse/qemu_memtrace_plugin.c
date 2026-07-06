/*
 * QEMU TCG plugin: emit a full memory-access trace as CSV, straight to QEMU's
 * plugin log. One row per event, in execution order:
 *
 *     type,address,size
 *     I,<vaddr>,<bytes>     instruction fetch (every executed instruction)
 *     L,<vaddr>,<bytes>     memory load
 *     S,<vaddr>,<bytes>     memory store
 *
 * This is the QEMU counterpart of the valgrind/lackey trace the rest of the
 * pipeline consumes (scripts/analyse/measure_valgrind_startup_and_request.sh):
 * same columns, same meaning, so the analysis scripts work unchanged. QEMU is
 * used instead of valgrind because valgrind's synthetic client stack cannot
 * survive Scala Native's startup stack-overflow-guard probe, whereas QEMU
 * emulates the program faithfully (delivering the guest's own signals).
 *
 * Unlike the stock `execlog` contrib plugin, this records the *size* of every
 * memory access (execlog omits it) and writes the final CSV directly.
 *
 * Throughput: output is buffered per vCPU and flushed in bulk. Calling
 * qemu_plugin_outs() once per instruction/access (as execlog does) is far too
 * slow for a managed-runtime startup (hundreds of millions of events); batching
 * into ~4 MB chunks per vCPU cuts the logging syscalls by ~10000x.
 *
 * Build (standalone, against the in-tree plugin header + glib):
 *   gcc -O2 -shared -fPIC -I third_party/qemu/include/qemu \
 *       $(pkg-config --cflags glib-2.0) qemu_memtrace_plugin.c \
 *       -o libmemtrace.so $(pkg-config --libs glib-2.0)
 */

#include <inttypes.h>
#include <stdio.h>

#include <glib.h>
#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

/* Flush a vCPU's buffer once it grows past this. */
#define FLUSH_THRESHOLD (4 * 1024 * 1024)

/* One output buffer per vCPU, so threads never contend on a shared buffer.
 * Expanded under a writer lock (rarely -- only as new vCPUs appear); the hot
 * path takes only the reader lock, mirroring the stock execlog plugin. */
typedef struct {
    GString *buf;
} CPUBuf;

static GArray *cpus;
static GRWLock cpus_lock;

/* When false (plugin arg "nomem"), skip load/store rows and emit only
 * instruction fetches -- a ~3x smaller trace for the ordering/page analyses,
 * which only consume I rows. The default (true) records everything. */
static bool trace_mem = true;

static CPUBuf *get_cpu(unsigned int index)
{
    CPUBuf *c;
    g_rw_lock_reader_lock(&cpus_lock);
    if (index >= cpus->len) {
        g_rw_lock_reader_unlock(&cpus_lock);
        g_rw_lock_writer_lock(&cpus_lock);
        while (index >= cpus->len) {
            CPUBuf nc = { g_string_sized_new(FLUSH_THRESHOLD + 4096) };
            g_array_append_val(cpus, nc);
        }
        g_rw_lock_writer_unlock(&cpus_lock);
        g_rw_lock_reader_lock(&cpus_lock);
    }
    c = &g_array_index(cpus, CPUBuf, index);
    g_rw_lock_reader_unlock(&cpus_lock);
    return c;
}

static inline void maybe_flush(CPUBuf *c)
{
    if (c->buf->len >= FLUSH_THRESHOLD) {
        qemu_plugin_outs(c->buf->str);
        g_string_set_size(c->buf, 0);
    }
}

/* Fires on every executed instruction. udata is the pre-built "I,addr,size\n"
 * line for this static instruction (built once at translation time). */
static void insn_exec(unsigned int cpu_index, void *udata)
{
    CPUBuf *c = get_cpu(cpu_index);
    g_string_append(c->buf, (const char *)udata);
    maybe_flush(c);
}

/* Fires on every memory access. Size and store/load are only known here. */
static void mem_access(unsigned int cpu_index, qemu_plugin_meminfo_t info,
                       uint64_t vaddr, void *udata)
{
    CPUBuf *c = get_cpu(cpu_index);
    unsigned int size = 1u << qemu_plugin_mem_size_shift(info);
    char type = qemu_plugin_mem_is_store(info) ? 'S' : 'L';
    g_string_append_printf(c->buf, "%c,%" PRIx64 ",%u\n", type, vaddr, size);
    maybe_flush(c);
}

/* Called once per translated block: wire callbacks onto each instruction. */
static void tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    size_t n_insns = qemu_plugin_tb_n_insns(tb);
    for (size_t i = 0; i < n_insns; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        uint64_t vaddr = qemu_plugin_insn_vaddr(insn);
        size_t size = qemu_plugin_insn_size(insn);
        /* Build the instruction line once; the exec cb just appends it. Leaked
         * intentionally -- one small alloc per static instruction. */
        char *line = g_strdup_printf("I,%" PRIx64 ",%zu\n", vaddr, size);
        qemu_plugin_register_vcpu_insn_exec_cb(insn, insn_exec,
                                               QEMU_PLUGIN_CB_NO_REGS, line);
        if (trace_mem) {
            qemu_plugin_register_vcpu_mem_cb(insn, mem_access,
                                             QEMU_PLUGIN_CB_NO_REGS,
                                             QEMU_PLUGIN_MEM_RW, NULL);
        }
    }
}

/* Flush every vCPU's remaining buffer at exit. */
static void at_exit(qemu_plugin_id_t id, void *udata)
{
    g_rw_lock_reader_lock(&cpus_lock);
    for (guint i = 0; i < cpus->len; i++) {
        CPUBuf *c = &g_array_index(cpus, CPUBuf, i);
        if (c->buf->len) {
            qemu_plugin_outs(c->buf->str);
            g_string_set_size(c->buf, 0);
        }
    }
    g_rw_lock_reader_unlock(&cpus_lock);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const qemu_info_t *info,
                                           int argc, char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (g_strcmp0(argv[i], "nomem") == 0) {
            trace_mem = false;
        }
    }
    cpus = g_array_new(false, false, sizeof(CPUBuf));
    qemu_plugin_outs("type,address,size\n");
    qemu_plugin_register_vcpu_tb_trans_cb(id, tb_trans);
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
