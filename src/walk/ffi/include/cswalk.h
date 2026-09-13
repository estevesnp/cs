#include <stdbool.h>
#include <stdint.h>

/*
 * opaque handle for internal use
 */
typedef struct CsHandle CsHandle;

/*
 * result of a project search
 */
typedef struct CsSearchResult {
    /*
     * handle to use with `cs_free_projects`, even if the search did not succeed.
     * may be null.
     */
    CsHandle *handle;
    /*
     * returned paths. check `count` for the number of returned projects.
     * may be null.
     */
    const char *const *paths;
    /*
     * number of `paths` returned.
     */
    uint32_t count;
    /*
     * whether the project search succeeded.
     * even if this is false, `cs_search_projects` should be called.
     */
    bool ok;
} CsSearchResult;

/*
 * options passed to `cs_search_projects`
 */
typedef struct CsSearchOpts {
    /*
     * markers used to identify projects.
     * `markers_count` should be the number of markers provided.
     * defaults to `.git` and `.jj` if null or empty.
     */
    const char *const *project_markers;
    /*
     * number of markers in `project_markers`.
     */
    uint32_t markers_count;
    /*
     * depth from the roots to search for projects.
     * if == 0, just checks the roots themselves.
     * if < 0, defaults to 5.
     */
    int32_t max_depth;
    /*
     * whether to continue or stop searching for a project from a root after
     * finding a marker.
     */
    bool continue_on_marker;
    /*
     * whether to log to stderr possible warnings or errors, such as a root that
     * doesn't exist
     */
    bool enable_logging;
} CsSearchOpts;

/*
 * search for projects starting from roots.
 * the handle from the result should always be freed using `cs_free_projects`,
 * even if it resulted in errors.
 * the returned projects are valid until the handle is freed.
 */
CsSearchResult cs_search_projects(
    /*
     * roots to search from.
     * `root_count` should be the number of roots provided.
     */
    const char *const *root_paths,
    /*
     * number of roots in `root_paths`.
     */
    uint32_t root_count,
    /*
     * options for searching for projects.
     */
    CsSearchOpts search_opts);

/*
 * free resources from `cs_search_projects`.
 * invalidates the returned projects.
 */
void cs_free_projects(
    /*
     * handle from the result of `cs_search_projects`
     */
    CsHandle *handle);
