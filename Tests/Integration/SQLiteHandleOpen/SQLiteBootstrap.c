#include "SQLiteBootstrap.h"
#include <sqlite3.h>

int sqlite_handle_open_bootstrap(void) {
    int result = sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 1);
    if (result != SQLITE_OK) {
        return result;
    }
    return sqlite3_initialize();
}
