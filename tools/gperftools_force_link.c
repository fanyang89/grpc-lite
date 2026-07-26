extern int ProfilerStart(const char *path);
extern void HeapProfilerStart(const char *prefix);

__attribute__((used, retain)) static const void *grpc_lite_gperftools_symbols[] = {
    (const void *)&ProfilerStart,
    (const void *)&HeapProfilerStart,
};
