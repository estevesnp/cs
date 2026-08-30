#include <stdbool.h>
#include <stdint.h>

typedef struct SearchResult {
    char **paths;
    uint32_t count;
    bool ok;
} SearchResult;

typedef struct SearchOpts {
    char **project_markers;
    uint32_t max_depth;
    bool enable_logging;
} SearchOpts;

SearchResult search_projects(char **root_paths, SearchOpts search_opts);

void free_projects(char **projects);
