#include <stdbool.h>
#include <stdint.h>

typedef struct CsSearchResult {
    const char *const *paths;
    uint32_t count;
    bool ok;
} CsSearchResult;

typedef struct CsSearchOpts {
    const char *const *project_markers;
    uint32_t markers_count;
    uint32_t max_depth;
    bool enable_logging;
} CsSearchOpts;

CsSearchResult cs_search_projects(const char *const *root_paths, uint32_t root_count, CsSearchOpts search_opts);

void cs_free_projects(const char *const *projects, uint32_t project_count);
