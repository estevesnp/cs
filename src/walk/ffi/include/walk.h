#include <stdbool.h>
#include <stdint.h>

typedef struct SearchResult {
    const char **paths;
    uint32_t count;
    bool ok;
} SearchResult;

typedef struct SearchOpts {
    const char **project_markers;
    uint32_t markers_count;
    uint32_t max_depth;
    bool enable_logging;
} SearchOpts;

SearchResult search_projects(const char **root_paths, uint32_t root_count, SearchOpts search_opts);

void free_projects(const char **projects, uint32_t project_count);
