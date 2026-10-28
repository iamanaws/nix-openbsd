package main

/*
#cgo pkg-config: sqlite3
#include <sqlite3.h>

static int sqlite_answer(void) {
	sqlite3 *db = 0;
	sqlite3_stmt *query = 0;
	int answer = -1;
	if (sqlite3_open(":memory:", &db) != SQLITE_OK)
		return -1;
	if (sqlite3_prepare_v2(db, "select 6 * 7", -1, &query, 0) == SQLITE_OK &&
	    sqlite3_step(query) == SQLITE_ROW)
		answer = sqlite3_column_int(query, 0);
	sqlite3_finalize(query);
	sqlite3_close(db);
	return answer;
}
*/
import "C"

import "fmt"

func main() {
	answer := int(C.sqlite_answer())
	if answer != 42 {
		panic(fmt.Sprintf("SQLite returned %d", answer))
	}
	fmt.Printf("SQLite through cgo: %d\n", answer)
}
