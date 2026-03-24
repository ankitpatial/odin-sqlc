# Foundation Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundational packages that everything else depends on: pg/ extensions (Error enum + value helpers), pg_query/ (libpg_query C bindings), and ast/ types (Node tagged union + struct definitions + AST enums).

**Architecture:** Three independent packages with no cross-dependencies in this plan. ast/ depends on nothing, pg/ depends on nothing, pg_query/ depends on nothing (the ast/ dependency is added when ast/convert.odin is implemented in the next plan — for now pg_query returns raw JSON). Each package wraps a C library via Odin foreign imports. Tests use Odin's built-in `@(test)` framework.

**Tech Stack:** Odin (dev-2026-03), libpg_query (v17, built from source), libpq (system-installed via PostgreSQL)

**Spec:** `docs/superpowers/specs/2026-03-24-odin-sqlc-design.md`

---

## File Structure

### pg/ package (extending existing)
- Create: `pg/error.odin` — Error enum + check_result proc
- Create: `pg/value.odin` — typed value extraction from Result
- Existing: `pg/pg.odin` — unchanged, provides Conn, Result, Exec_Status, etc.
- Note: pg/ tests require a live PostgreSQL connection and will be added in a later plan

### pg_query/ package (new)
- Create: `pg_query/pg_query.odin` — C FFI bindings to libpg_query
- Create: `pg_query/parse.odin` — higher-level parse wrapper (JSON → []Raw_Stmt)
- Create: `pg_query/tests/pg_query_test.odin` — tests for parsing SQL
- Create: `scripts/build_libpg_query.sh` — build script for the C library

### ast/ package (new)
- Create: `ast/enums.odin` — all AST enums (Set_Operation, Bool_Expr_Type, etc.)
- Create: `ast/types.odin` — identifier structs (Table_Name, Type_Name, Func_Name, etc.)
- Create: `ast/stmt.odin` — statement structs (Select_Stmt, Insert_Stmt, etc.)
- Create: `ast/expr.odin` — expression structs (A_Expr, Func_Call, etc.)
- Create: `ast/ddl.odin` — DDL structs (Create_Table_Stmt, Alter_Table_Stmt, etc.)
- Create: `ast/node.odin` — Node tagged union aggregating all types
- Create: `ast/tests/node_test.odin` — tests for Node construction and pattern matching

---

## Task 1: Build libpg_query from Source

**Files:**
- Create: `scripts/build_libpg_query.sh`
- Create: `vendor/libpg_query/.gitkeep` (output directory)

- [ ] **Step 1: Create the build script**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_DIR/vendor/libpg_query"
VERSION="17-6.2.0"

if [ -f "$VENDOR_DIR/lib/libpg_query.a" ]; then
    echo "libpg_query already built at $VENDOR_DIR/lib/libpg_query.a"
    exit 0
fi

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Cloning libpg_query $VERSION..."
git clone --depth 1 --branch "$VERSION" https://github.com/pganalyze/libpg_query.git "$TEMP_DIR/libpg_query"

echo "Building..."
cd "$TEMP_DIR/libpg_query"
make build

echo "Installing to $VENDOR_DIR..."
mkdir -p "$VENDOR_DIR/lib" "$VENDOR_DIR/include"
cp build/libpg_query.a "$VENDOR_DIR/lib/"
cp pg_query.h "$VENDOR_DIR/include/"

echo "Done. Library: $VENDOR_DIR/lib/libpg_query.a"
echo "Done. Header:  $VENDOR_DIR/include/pg_query.h"
```

- [ ] **Step 2: Run the build script**

Run: `chmod +x scripts/build_libpg_query.sh && ./scripts/build_libpg_query.sh`
Expected: `libpg_query.a` and `pg_query.h` in `vendor/libpg_query/`

- [ ] **Step 3: Verify the build artifacts**

Run: `ls -la vendor/libpg_query/lib/libpg_query.a vendor/libpg_query/include/pg_query.h`
Expected: Both files exist

- [ ] **Step 4: Add vendor directory to .gitignore**

Add to `.gitignore`:
```
vendor/libpg_query/lib/
vendor/libpg_query/include/
```

Keep the build script tracked, not the built artifacts.

- [ ] **Step 5: Commit**

```bash
git add scripts/build_libpg_query.sh .gitignore
git commit -m "feat: add build script for libpg_query C library"
```

---

## Task 2: pg/error.odin — Error Enum

**Files:**
- Create: `pg/error.odin`

- [ ] **Step 1: Write the error enum and check_result proc**

```odin
package pq

// Error represents the outcome of a PostgreSQL operation.
// Default value is .None (no error).
Error :: enum {
	None,
	Empty_Query,
	Bad_Response,
	Nonfatal_Error,
	Fatal_Error,
	Pipeline_Aborted,
	Connection_Bad,
	Out_Of_Memory,
}

// Maps a libpq Exec_Status to our Error enum.
// Returns .None for successful statuses (Command_OK, Tuples_OK, etc.).
check_result :: proc(res: Result) -> Error {
	if res == nil {
		return .Out_Of_Memory
	}

	status := result_status(res)

	switch status {
	case .Command_OK, .Tuples_OK, .Copy_Out, .Copy_In, .Copy_Both,
	     .Single_Tuple, .Pipeline_Sync, .Tuples_Chunk:
		return .None
	case .Empty_Query:
		return .Empty_Query
	case .Bad_Response:
		return .Bad_Response
	case .Non_Fatal_Error:
		return .Nonfatal_Error
	case .Fatal_Error:
		return .Fatal_Error
	case .Pipeline_Aborted:
		return .Pipeline_Aborted
	}

	return .Fatal_Error
}

// Returns the error message from a result, or empty string if no error.
// The returned cstring is owned by the Result — do not free it.
result_error :: proc(res: Result) -> cstring {
	if res == nil {
		return "out of memory"
	}
	return result_error_message(res)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check pg/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add pg/error.odin
git commit -m "feat(pg): add Error enum and check_result proc"
```

---

## Task 3: pg/value.odin — Value Extraction Helpers

**Files:**
- Create: `pg/value.odin`

- [ ] **Step 1: Write the value extraction procs**

```odin
package pq

import "core:strconv"
import "core:strings"

// Get a text field value as a string. Returns (value, ok).
// The returned string is cloned into the given allocator.
// Returns ("", false) if the field is NULL.
get_string :: proc(
	res: Result,
	row: i32,
	col: i32,
	allocator := context.allocator,
) -> (string, bool) {
	if get_is_null(res, row, col) {
		return "", false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return "", true
	}
	src := (cast([^]byte)raw)[:length]
	return strings.clone_from_bytes(src, allocator), true
}

// Get a Maybe(string) — returns nil for NULL columns.
get_maybe_string :: proc(
	res: Result,
	row: i32,
	col: i32,
	allocator := context.allocator,
) -> Maybe(string) {
	val, ok := get_string(res, row, col, allocator)
	if !ok {
		return nil
	}
	return val
}

// Get a text field as i32. Returns (value, ok).
get_i32 :: proc(res: Result, row: i32, col: i32) -> (i32, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string((cast([^]byte)raw)[:length])
	val, ok := strconv.parse_int(text)
	if !ok {
		return 0, false
	}
	return i32(val), true
}

// Get a Maybe(i32).
get_maybe_i32 :: proc(res: Result, row: i32, col: i32) -> Maybe(i32) {
	val, ok := get_i32(res, row, col)
	if !ok {
		return nil
	}
	return val
}

// Get a text field as i64. Returns (value, ok).
get_i64 :: proc(res: Result, row: i32, col: i32) -> (i64, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string((cast([^]byte)raw)[:length])
	val, ok := strconv.parse_int(text)
	if !ok {
		return 0, false
	}
	return i64(val), true
}

// Get a Maybe(i64).
get_maybe_i64 :: proc(res: Result, row: i32, col: i32) -> Maybe(i64) {
	val, ok := get_i64(res, row, col)
	if !ok {
		return nil
	}
	return val
}

// Get a text field as i16. Returns (value, ok).
get_i16 :: proc(res: Result, row: i32, col: i32) -> (i16, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string((cast([^]byte)raw)[:length])
	val, ok := strconv.parse_int(text)
	if !ok {
		return 0, false
	}
	return i16(val), true
}

// Get a Maybe(i16).
get_maybe_i16 :: proc(res: Result, row: i32, col: i32) -> Maybe(i16) {
	val, ok := get_i16(res, row, col)
	if !ok {
		return nil
	}
	return val
}

// Get a text field as f64. Returns (value, ok).
get_f64 :: proc(res: Result, row: i32, col: i32) -> (f64, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string((cast([^]byte)raw)[:length])
	val, ok := strconv.parse_f64(text)
	if !ok {
		return 0, false
	}
	return val, true
}

// Get a Maybe(f64).
get_maybe_f64 :: proc(res: Result, row: i32, col: i32) -> Maybe(f64) {
	val, ok := get_f64(res, row, col)
	if !ok {
		return nil
	}
	return val
}

// Get a text field as f32. Returns (value, ok).
get_f32 :: proc(res: Result, row: i32, col: i32) -> (f32, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string((cast([^]byte)raw)[:length])
	val, ok := strconv.parse_f64(text)
	if !ok {
		return 0, false
	}
	return f32(val), true
}

// Get a Maybe(f32).
get_maybe_f32 :: proc(res: Result, row: i32, col: i32) -> Maybe(f32) {
	val, ok := get_f32(res, row, col)
	if !ok {
		return nil
	}
	return val
}

// Get a text field as bool. PostgreSQL returns "t" or "f".
get_bool :: proc(res: Result, row: i32, col: i32) -> (bool, bool) {
	if get_is_null(res, row, col) {
		return false, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return false, false
	}
	first_byte := (cast([^]byte)raw)[0]
	return first_byte == 't' || first_byte == 'T', true
}

// Get a Maybe(bool).
get_maybe_bool :: proc(res: Result, row: i32, col: i32) -> Maybe(bool) {
	val, ok := get_bool(res, row, col)
	if !ok {
		return nil
	}
	return val
}

// Get a binary field as []byte. Returns (value, ok).
// The returned slice is cloned into the given allocator.
get_bytes :: proc(
	res: Result,
	row: i32,
	col: i32,
	allocator := context.allocator,
) -> ([]byte, bool) {
	if get_is_null(res, row, col) {
		return nil, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return nil, true
	}
	src := (cast([^]byte)raw)[:length]
	dst := make([]byte, length, allocator)
	copy(dst, src)
	return dst, true
}

// Get a Maybe([]byte).
get_maybe_bytes :: proc(
	res: Result,
	row: i32,
	col: i32,
	allocator := context.allocator,
) -> Maybe([]byte) {
	val, ok := get_bytes(res, row, col, allocator)
	if !ok {
		return nil
	}
	return val
}

// Parse the rows-affected count from cmd_tuples. Returns (count, ok).
get_rows_affected :: proc(res: Result) -> (i64, bool) {
	ct := cmd_tuples(res)
	if ct == nil {
		return 0, false
	}
	text := string(ct)
	if len(text) == 0 {
		return 0, true
	}
	val, ok := strconv.parse_int(text)
	if !ok {
		return 0, false
	}
	return i64(val), true
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check pg/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add pg/value.odin
git commit -m "feat(pg): add typed value extraction helpers"
```

---

## Task 4: ast/enums.odin — AST Enumerations

**Files:**
- Create: `ast/enums.odin`

- [ ] **Step 1: Create the ast package and enums file**

```odin
package ast

// Set operations for UNION/INTERSECT/EXCEPT
Set_Operation :: enum {
	None,
	Union,
	Intersect,
	Except,
}

// Boolean expression types
Bool_Expr_Type :: enum {
	And,
	Or,
	Not,
}

// Expression kinds for A_Expr
A_Expr_Kind :: enum {
	Normal,    // normal operator
	Op,        // operator (same as Normal in most contexts)
	Like,      // LIKE
	ILike,     // ILIKE
	Similar,   // SIMILAR TO
	Between,   // BETWEEN
	Not_Between, // NOT BETWEEN
	In,        // IN
	Not_In,    // NOT IN
}

// Subquery link types
Sub_Link_Type :: enum {
	Exists,
	All,
	Any,
	Row_Compare,
	Expr,
	Multiexpr,
	Array,
}

// Function parameter modes
Func_Param_Mode :: enum {
	In,
	Out,
	In_Out,
	Variadic,
	Table,
	Default,
}

// DROP behavior
Drop_Behavior :: enum {
	Restrict,
	Cascade,
}

// Object types for DROP/ALTER
Object_Type :: enum {
	Table,
	Sequence,
	View,
	Materialized_View,
	Index,
	Foreign_Table,
	Type,
	Schema,
	Function,
	Procedure,
	Aggregate,
	Operator,
	Extension,
	Policy,
	Rule,
	Trigger,
	Event_Trigger,
	Collation,
	Conversion,
	Domain,
	Access_Method,
	Cast,
}

// NULL test types
Null_Test_Type :: enum {
	Is_Null,
	Is_Not_Null,
}

// Sort order
Sort_By_Dir :: enum {
	Default,
	Asc,
	Desc,
	Using,
}

// NULL ordering
Sort_By_Nulls :: enum {
	Default,
	First,
	Last,
}

// JOIN types
Join_Type :: enum {
	Inner,
	Left,
	Full,
	Right,
	Semi,
	Anti,
	Unique_Inner,
	Unique_Outer,
}

// Constraint types
Constraint_Type :: enum {
	Null,
	Not_Null,
	Default,
	Identity,
	Generated,
	Check,
	Primary_Key,
	Unique,
	Exclusion,
	Foreign_Key,
	Attr_Deferrable,
	Attr_Not_Deferrable,
	Attr_Deferred,
	Attr_Immediate,
}

// ALTER TABLE subcommand types
Alter_Table_Type :: enum {
	Add_Column,
	Drop_Column,
	Alter_Column_Type,
	Alter_Column_Set_Default,
	Alter_Column_Drop_Default,
	Alter_Column_Set_Not_Null,
	Alter_Column_Drop_Not_Null,
	Add_Constraint,
	Drop_Constraint,
	Set_Schema,
	Set_Owner,
	Rename_Column,
	Rename_Table,
	Add_Index,
}

// On conflict action
On_Conflict_Action :: enum {
	None,
	Nothing,
	Update,
}

// Constant value types
A_Const_Type :: enum {
	Integer,
	Float,
	Boolean,
	String,
	Bit_String,
	Null,
}

// Foreign key actions
FK_Action :: enum {
	No_Action,
	Restrict,
	Cascade,
	Set_Null,
	Set_Default,
}

// DefElem action (for SET, ADD, DROP)
Def_Elem_Action :: enum {
	Unspec,
	Set,
	Add,
	Drop,
}

// Keyword for GRANT/REVOKE
Grant_Target_Type :: enum {
	Object,
	All_In_Schema,
	Defaults,
}

// Lock clause strength (FOR UPDATE/SHARE)
Lock_Clause_Strength :: enum {
	None,
	For_Key_Share,
	For_Share,
	For_No_Key_Update,
	For_Update,
}

// Limit option
Limit_Option :: enum {
	Default,
	Count,
	Percent,
	With_Ties,
}

// Grouping set kind
Grouping_Set_Kind :: enum {
	Empty,
	Simple,
	Rollup,
	Cube,
	Sets,
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add ast/enums.odin
git commit -m "feat(ast): add AST enumeration types"
```

---

## Task 5: ast/types.odin — Identifier Structs

**Files:**
- Create: `ast/types.odin`

- [ ] **Step 1: Write the identifier and reference structs**

```odin
package ast

// Qualified table name (catalog.schema.name)
Table_Name :: struct {
	catalog: string,
	schema:  string,
	name:    string,
}

// Qualified type name
Type_Name :: struct {
	catalog:      string,
	schema:       string,
	name:         string,
	array_bounds: [dynamic]^Node,
	set_of:       bool,
	pct_type:     bool,  // %TYPE notation
	typmods:      [dynamic]^Node,
	location:     i32,
}

// Qualified function name
Func_Name :: struct {
	catalog: string,
	schema:  string,
	name:    string,
}

// A raw statement from the parser with location info
Raw_Stmt :: struct {
	stmt:     ^Node,
	location: i32,  // byte offset in source
	length:   i32,  // byte length (0 = to end)
}

// Wraps a raw statement for catalog processing
Statement :: struct {
	raw: Raw_Stmt,
}

// Column reference (table.column or just column)
Column_Ref :: struct {
	fields:   [dynamic]^Node,  // String nodes or A_Star
	location: i32,
}

// Parameter reference ($1, $2, ...)
Param_Ref :: struct {
	number:   i32,
	location: i32,
}

// A_Star represents * in SELECT * or table.*
A_Star :: struct {
	location: i32,
}

// A_Const represents a constant value
A_Const :: struct {
	type: A_Const_Type,
	ival: i64,
	fval: string,
	bval: bool,
	sval: string,
	bsval: string,  // bit string
	location: i32,
}

// String node (used in lists like column ref fields)
String_Node :: struct {
	sval: string,
}

// Integer node
Integer_Node :: struct {
	ival: i64,
}

// Float node (stored as string for precision)
Float_Node :: struct {
	fval: string,
}

// Boolean node
Boolean_Node :: struct {
	boolval: bool,
}

// Table alias
Alias :: struct {
	aliasname: string,
	colnames:  [dynamic]^Node,
}

// Range variable (table reference in FROM clause)
Range_Var :: struct {
	catalogname: string,
	schemaname:  string,
	relname:     string,
	inh:         bool,  // inheritance?
	relpersistence: byte,  // 'p', 'u', 't'
	alias:       ^Alias,
	location:    i32,
}

// Result target (SELECT target list item or INSERT/UPDATE column)
Res_Target :: struct {
	name:        string,   // column name (for INSERT/UPDATE) or alias (for SELECT)
	indirection: [dynamic]^Node,
	val:         ^Node,    // expression
	location:    i32,
}

// Column definition (in CREATE TABLE)
Column_Def :: struct {
	colname:      string,
	type_name:    ^Type_Name,
	compression:  string,
	inhcount:     i32,
	is_local:     bool,
	is_not_null:  bool,
	is_from_type: bool,
	storage:      byte,
	raw_default:  ^Node,
	cooked_default: ^Node,
	identity:     byte,
	generated:    byte,
	coll_clause:  ^Node,
	coll_oid:     u32,
	constraints:  [dynamic]^Node,
	fdwoptions:   [dynamic]^Node,
	location:     i32,
}

// Constraint definition
Constraint :: struct {
	contype:         Constraint_Type,
	conname:         string,
	deferrable:      bool,
	initdeferred:    bool,
	location:        i32,
	is_no_inherit:   bool,
	raw_expr:        ^Node,
	cooked_expr:     string,
	generated_when:  byte,
	keys:            [dynamic]^Node,
	including:       [dynamic]^Node,
	exclusions:      [dynamic]^Node,
	options:         [dynamic]^Node,
	indexname:       string,
	indexspace:      string,
	reset_default_tblspc: bool,
	access_method:   string,
	where_clause:    ^Node,
	pktable:         ^Range_Var,
	fk_attrs:        [dynamic]^Node,
	pk_attrs:        [dynamic]^Node,
	fk_matchtype:    byte,
	fk_upd_action:   byte,
	fk_del_action:   byte,
	fk_del_set_cols: [dynamic]^Node,
	old_conpfeqop:   [dynamic]^Node,
	old_pktable_oid: u32,
	skip_validation: bool,
	initially_valid: bool,
}

// WITH clause
With_Clause :: struct {
	ctes:      [dynamic]^Node,
	recursive: bool,
	location:  i32,
}

// Common Table Expression (CTE)
Common_Table_Expr :: struct {
	ctename:       string,
	aliascolnames: [dynamic]^Node,
	ctematerialized: i32,
	ctequery:      ^Node,
	location:      i32,
	cterecursive:  bool,
	cterefcount:   i32,
	ctecolnames:   [dynamic]^Node,
	ctecoltypes:   [dynamic]^Node,
	ctecoltypmods: [dynamic]^Node,
	ctecolcollations: [dynamic]^Node,
}

// ON CONFLICT clause
On_Conflict_Clause :: struct {
	action:       On_Conflict_Action,
	infer:        ^Node,    // InferClause
	target_list:  [dynamic]^Node,
	where_clause: ^Node,
	location:     i32,
}

// Sort-by clause (ORDER BY item)
Sort_By :: struct {
	node:         ^Node,
	sortby_dir:   Sort_By_Dir,
	sortby_nulls: Sort_By_Nulls,
	use_op:       [dynamic]^Node,
	location:     i32,
}

// Window definition
Window_Def :: struct {
	name:            string,
	refname:         string,
	partition_clause: [dynamic]^Node,
	order_clause:    [dynamic]^Node,
	frame_options:   i32,
	start_offset:    ^Node,
	end_offset:      ^Node,
	location:        i32,
}

// Locking clause (FOR UPDATE/SHARE)
Locking_Clause :: struct {
	locked_rels: [dynamic]^Node,
	strength:    Lock_Clause_Strength,
	wait_policy: i32,
}

// Generic List (used throughout the AST)
List :: struct {
	items: [dynamic]^Node,
}

// Infer clause (for ON CONFLICT)
Infer_Clause :: struct {
	index_elems:  [dynamic]^Node,
	where_clause: ^Node,
	conname:      string,
	location:     i32,
}

// Index element
Index_Elem :: struct {
	name:        string,
	expr:        ^Node,
	indexcolname: string,
	collation:   [dynamic]^Node,
	opclass:     [dynamic]^Node,
	opclassopts: [dynamic]^Node,
	ordering:    Sort_By_Dir,
	nulls_ordering: Sort_By_Nulls,
}

// Multi-assign reference (for UPDATE SET (a,b) = (SELECT ...))
Multi_Assign_Ref :: struct {
	source:   ^Node,
	colno:    i32,
	ncolumns: i32,
}

// Grouping Set
Grouping_Set :: struct {
	kind:     Grouping_Set_Kind,
	content:  [dynamic]^Node,
	location: i32,
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors (Node is not yet defined, so ^Node references will fail — we need a forward declaration or stub)

Note: Since `^Node` is referenced but `Node` isn't defined yet, create a minimal stub in `ast/node.odin`:

```odin
package ast

// Forward declaration — full union defined after all types are in place.
// For now, a placeholder so other files compile.
Node :: struct {}
```

- [ ] **Step 3: Verify with stub**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add ast/types.odin ast/node.odin
git commit -m "feat(ast): add identifier and reference types with Node stub"
```

---

## Task 6: ast/stmt.odin — Statement Structs

**Files:**
- Create: `ast/stmt.odin`

- [ ] **Step 1: Write the DML statement structs**

```odin
package ast

// SELECT statement
Select_Stmt :: struct {
	distinct_clause: [dynamic]^Node,
	into_clause:     ^Node,  // IntoClause
	target_list:     [dynamic]^Node,
	from_clause:     [dynamic]^Node,
	where_clause:    ^Node,
	group_clause:    [dynamic]^Node,
	group_distinct:  bool,
	having_clause:   ^Node,
	window_clause:   [dynamic]^Node,
	values_lists:    [dynamic][dynamic]^Node,
	sort_clause:     [dynamic]^Node,
	limit_offset:    ^Node,
	limit_count:     ^Node,
	limit_option:    Limit_Option,
	locking_clause:  [dynamic]^Node,
	with_clause:     ^With_Clause,
	op:              Set_Operation,
	all:             bool,
	larg:            ^Select_Stmt,
	rarg:            ^Select_Stmt,
}

// INSERT statement
Insert_Stmt :: struct {
	relation:         ^Range_Var,
	cols:             [dynamic]^Node,
	select_stmt:      ^Node,  // SELECT or VALUES
	on_conflict:      ^On_Conflict_Clause,
	returning_list:   [dynamic]^Node,
	with_clause:      ^With_Clause,
	override:         i32,  // OverridingKind
}

// UPDATE statement
Update_Stmt :: struct {
	relation:       ^Range_Var,
	target_list:    [dynamic]^Node,
	where_clause:   ^Node,
	from_clause:    [dynamic]^Node,
	returning_list: [dynamic]^Node,
	with_clause:    ^With_Clause,
}

// DELETE statement
Delete_Stmt :: struct {
	relation:       ^Range_Var,
	using_clause:   [dynamic]^Node,
	where_clause:   ^Node,
	returning_list: [dynamic]^Node,
	with_clause:    ^With_Clause,
}

// TRUNCATE statement
Truncate_Stmt :: struct {
	relations: [dynamic]^Node,
	restart_seqs: bool,
	behavior:  Drop_Behavior,
}

// EXPLAIN statement
Explain_Stmt :: struct {
	query:   ^Node,
	options: [dynamic]^Node,
}

// COPY statement
Copy_Stmt :: struct {
	relation:  ^Range_Var,
	query:     ^Node,
	attlist:   [dynamic]^Node,
	is_from:   bool,
	is_program: bool,
	filename:  string,
	options:   [dynamic]^Node,
	where_clause: ^Node,
}

// Range subselect (subquery in FROM)
Range_Subselect :: struct {
	lateral:  bool,
	subquery: ^Node,
	alias:    ^Alias,
}

// Range function (function call in FROM)
Range_Function :: struct {
	lateral:     bool,
	ordinality:  bool,
	is_rowsfrom: bool,
	functions:   [dynamic]^Node,
	alias:       ^Alias,
	coldeflist:  [dynamic]^Node,
}

// JOIN expression
Join_Expr :: struct {
	jointype:    Join_Type,
	is_natural:  bool,
	larg:        ^Node,
	rarg:        ^Node,
	using_clause: [dynamic]^Node,
	join_using_alias: ^Alias,
	quals:       ^Node,
	alias:       ^Alias,
}

// INTO clause (SELECT INTO)
Into_Clause :: struct {
	rel:             ^Range_Var,
	col_names:       [dynamic]^Node,
	access_method:   string,
	options:         [dynamic]^Node,
	on_commit:       i32,
	tablespacename:  string,
	view_query:      ^Node,
	skip_data:       bool,
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add ast/stmt.odin
git commit -m "feat(ast): add DML statement types"
```

---

## Task 7: ast/expr.odin — Expression Structs

**Files:**
- Create: `ast/expr.odin`

- [ ] **Step 1: Write the expression structs**

```odin
package ast

// General expression (a op b, a LIKE b, etc.)
A_Expr :: struct {
	kind:     A_Expr_Kind,
	name:     [dynamic]^Node,  // operator name
	lexpr:    ^Node,           // left operand
	rexpr:    ^Node,           // right operand
	location: i32,
}

// Boolean expression (AND, OR, NOT)
Bool_Expr :: struct {
	boolop: Bool_Expr_Type,
	args:   [dynamic]^Node,
	location: i32,
}

// Function call
Func_Call :: struct {
	funcname:       [dynamic]^Node,  // qualified function name
	args:           [dynamic]^Node,
	agg_order:      [dynamic]^Node,
	agg_filter:     ^Node,
	over:           ^Window_Def,
	agg_within_group: bool,
	agg_star:       bool,
	agg_distinct:   bool,
	func_variadic:  bool,
	funcformat:     i32,  // CoercionForm
	location:       i32,
}

// Type cast (CAST or :: notation)
Type_Cast :: struct {
	arg:       ^Node,
	type_name: ^Type_Name,
	location:  i32,
}

// CASE expression
Case_Expr :: struct {
	casetype:  u32,
	casecollid: u32,
	arg:       ^Node,
	args:      [dynamic]^Node,  // WHEN clauses
	defresult: ^Node,           // ELSE clause
	location:  i32,
}

// WHEN clause (in CASE)
Case_When :: struct {
	expr:     ^Node,  // condition
	result:   ^Node,  // result value
	location: i32,
}

// Subquery link (EXISTS, IN, ANY, ALL, scalar subquery)
Sub_Link :: struct {
	sub_link_type: Sub_Link_Type,
	testexpr:      ^Node,
	oper_name:     [dynamic]^Node,
	subselect:     ^Node,  // Select_Stmt
	location:      i32,
}

// COALESCE expression
Coalesce_Expr :: struct {
	coalescetype: u32,
	coalescecollid: u32,
	args:         [dynamic]^Node,
	location:     i32,
}

// NULL test (IS NULL / IS NOT NULL)
Null_Test :: struct {
	arg:           ^Node,
	nulltesttype:  Null_Test_Type,
	argisrow:      bool,
	location:      i32,
}

// Boolean test (IS TRUE / IS NOT TRUE / IS FALSE / IS NOT FALSE / IS UNKNOWN / IS NOT UNKNOWN)
Boolean_Test :: struct {
	arg:       ^Node,
	booltesttype: i32,
	location:  i32,
}

// Row expression (ROW(a, b, c))
Row_Expr :: struct {
	args:      [dynamic]^Node,
	row_typeid: u32,
	row_format: i32,
	colnames:  [dynamic]^Node,
	location:  i32,
}

// Array expression (ARRAY[a, b, c])
A_Array_Expr :: struct {
	elements: [dynamic]^Node,
	location: i32,
}

// Array index (a[1])
A_Indices :: struct {
	is_slice: bool,
	lidx:     ^Node,
	uidx:     ^Node,
}

// Indirection (a.b, a[1], etc.)
A_Indirection :: struct {
	arg:         ^Node,
	indirection: [dynamic]^Node,
}

// MinMax expression (GREATEST/LEAST)
Min_Max_Expr :: struct {
	minmaxtype: u32,
	minmaxcollid: u32,
	inputcollid: u32,
	op:         i32,  // MinMaxOp
	args:       [dynamic]^Node,
	location:   i32,
}

// SQL/XML expression
Xml_Expr :: struct {
	op:         i32,
	name:       string,
	named_args: [dynamic]^Node,
	arg_names:  [dynamic]^Node,
	args:       [dynamic]^Node,
	xmloption:  i32,
	indent:     bool,
	type_id:    u32,
	typmod:     i32,
	location:   i32,
}

// SQLValueFunction (CURRENT_DATE, CURRENT_TIME, etc.)
Sql_Value_Function :: struct {
	op:       i32,
	type_id:  u32,
	typmod:   i32,
	location: i32,
}

// SetToDefault (DEFAULT keyword in INSERT/UPDATE)
Set_To_Default :: struct {
	type_id:  u32,
	typmod:   i32,
	collation: u32,
	location: i32,
}

// Parenthesized expression
Paren_Expr :: struct {
	arg:      ^Node,
	location: i32,
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add ast/expr.odin
git commit -m "feat(ast): add expression types"
```

---

## Task 8: ast/ddl.odin — DDL Structs

**Files:**
- Create: `ast/ddl.odin`

- [ ] **Step 1: Write the DDL statement structs**

```odin
package ast

// CREATE TABLE
Create_Table_Stmt :: struct {
	relation:      ^Range_Var,
	table_elts:    [dynamic]^Node,  // Column_Def and Constraint nodes
	inh_relations: [dynamic]^Node,  // inherited tables
	partbound:     ^Node,
	partspec:      ^Node,
	of_typename:   ^Type_Name,
	constraints:   [dynamic]^Node,
	options:       [dynamic]^Node,
	oncommit:      i32,
	tablespacename: string,
	access_method: string,
	if_not_exists: bool,
}

// ALTER TABLE
Alter_Table_Stmt :: struct {
	relation:   ^Range_Var,
	cmds:       [dynamic]^Node,  // Alter_Table_Cmd nodes
	objtype:    Object_Type,
	missing_ok: bool,
}

// ALTER TABLE subcommand
Alter_Table_Cmd :: struct {
	subtype:    Alter_Table_Type,
	name:       string,
	num:        i16,
	newowner:   ^Node,  // RoleSpec
	def:        ^Node,  // Column_Def, Constraint, etc.
	behavior:   Drop_Behavior,
	missing_ok: bool,
	recurse:    bool,
}

// DROP statement (table, type, function, schema, etc.)
Drop_Stmt :: struct {
	objects:    [dynamic]^Node,
	remove_type: Object_Type,
	behavior:   Drop_Behavior,
	missing_ok: bool,
	concurrent: bool,
}

// CREATE TYPE AS ENUM
Create_Enum_Stmt :: struct {
	type_name: [dynamic]^Node,  // qualified name
	vals:      [dynamic]^Node,  // String nodes
}

// ALTER TYPE (add value, rename value)
Alter_Enum_Stmt :: struct {
	type_name:          [dynamic]^Node,
	old_val:            string,
	new_val:            string,
	new_val_neighbor:   string,
	new_val_is_after:   bool,
	skip_if_new_val_exists: bool,
}

// CREATE FUNCTION / CREATE PROCEDURE
Create_Function_Stmt :: struct {
	is_procedure:  bool,
	replace:       bool,
	funcname:      [dynamic]^Node,
	parameters:    [dynamic]^Node,  // Function_Parameter nodes
	return_type:   ^Type_Name,
	options:       [dynamic]^Node,
	sql_body:      ^Node,
}

// Function parameter (in CREATE FUNCTION)
Function_Parameter :: struct {
	name:     string,
	arg_type: ^Type_Name,
	mode:     Func_Param_Mode,
	defexpr:  ^Node,
}

// DROP FUNCTION
Drop_Function_Stmt :: struct {
	objects:    [dynamic]^Node,
	behavior:   Drop_Behavior,
	missing_ok: bool,
}

// CREATE SCHEMA
Create_Schema_Stmt :: struct {
	schemaname:  string,
	authrole:    ^Node,  // RoleSpec
	schema_elts: [dynamic]^Node,
	if_not_exists: bool,
}

// DROP SCHEMA
Drop_Schema_Stmt :: struct {
	schemas:    [dynamic]string,
	behavior:   Drop_Behavior,
	missing_ok: bool,
}

// CREATE VIEW
Create_View_Stmt :: struct {
	view:         ^Range_Var,
	aliases:      [dynamic]^Node,
	query:        ^Node,  // SELECT statement
	replace:      bool,
	options:      [dynamic]^Node,
	with_check_option: i32,
}

// CREATE TABLE AS (SELECT ...)
Create_Table_As_Stmt :: struct {
	query:        ^Node,
	into:         ^Into_Clause,
	objtype:      Object_Type,
	is_select_into: bool,
	if_not_exists: bool,
}

// RENAME (table, column, type, schema)
Rename_Stmt :: struct {
	rename_type:  Object_Type,
	relation_type: Object_Type,
	relation:     ^Range_Var,
	object:       ^Node,
	subname:      string,  // old name
	newname:      string,  // new name
	behavior:     Drop_Behavior,
	missing_ok:   bool,
}

// COMMENT ON
Comment_Stmt :: struct {
	objtype: Object_Type,
	object:  ^Node,
	comment: string,
}

// ALTER TYPE SET SCHEMA / ALTER TABLE SET SCHEMA
Alter_Object_Schema_Stmt :: struct {
	object_type: Object_Type,
	relation:    ^Range_Var,
	object:      ^Node,
	newschema:   string,
	missing_ok:  bool,
}

// CREATE EXTENSION
Create_Extension_Stmt :: struct {
	extname:       string,
	if_not_exists: bool,
	options:       [dynamic]^Node,
}

// CREATE COMPOSITE TYPE
Composite_Type_Stmt :: struct {
	typevar:  ^Range_Var,
	coldeflist: [dynamic]^Node,
}

// CREATE INDEX
Index_Stmt :: struct {
	idxname:         string,
	relation:        ^Range_Var,
	access_method:   string,
	table_space:     string,
	index_params:    [dynamic]^Node,
	index_including_params: [dynamic]^Node,
	options:         [dynamic]^Node,
	where_clause:    ^Node,
	exclude_op_names: [dynamic]^Node,
	idxcomment:      string,
	index_oid:       u32,
	old_number:      u32,
	old_create_subid: u32,
	old_first_relfilelocator_subid: u32,
	unique:          bool,
	nulls_not_distinct: bool,
	primary:         bool,
	isconstraint:    bool,
	deferrable:      bool,
	initdeferred:    bool,
	transformed:     bool,
	concurrent:      bool,
	if_not_exists:   bool,
	reset_default_tblspc: bool,
}

// CREATE SEQUENCE
Create_Seq_Stmt :: struct {
	sequence:      ^Range_Var,
	options:       [dynamic]^Node,
	owner_id:      u32,
	for_identity:  bool,
	if_not_exists: bool,
}

// ALTER SEQUENCE
Alter_Seq_Stmt :: struct {
	sequence:     ^Range_Var,
	options:      [dynamic]^Node,
	for_identity: bool,
	missing_ok:   bool,
}

// GRANT / REVOKE
Grant_Stmt :: struct {
	is_grant:    bool,
	targtype:    Grant_Target_Type,
	objtype:     Object_Type,
	objects:     [dynamic]^Node,
	privileges:  [dynamic]^Node,
	grantees:    [dynamic]^Node,
	grant_option: bool,
	grantor:     ^Node,
	behavior:    Drop_Behavior,
}

// DefElem (generic key=value for SET, options, etc.)
Def_Elem :: struct {
	defnamespace: string,
	defname:      string,
	arg:          ^Node,
	defaction:    Def_Elem_Action,
	location:     i32,
}

// Role specification (for owner, grantee)
Role_Spec :: struct {
	roletype: i32,
	rolename: string,
	location: i32,
}

// Transaction statement (BEGIN, COMMIT, ROLLBACK)
Transaction_Stmt :: struct {
	kind:     i32,
	options:  [dynamic]^Node,
	savepoint_name: string,
	gid:      string,
	chain:    bool,
	location: i32,
}

// DO statement (anonymous code block)
Do_Stmt :: struct {
	args: [dynamic]^Node,
}

// PREPARE statement
Prepare_Stmt :: struct {
	name:     string,
	argtypes: [dynamic]^Node,
	query:    ^Node,
}

// EXECUTE statement
Execute_Stmt :: struct {
	name:   string,
	params: [dynamic]^Node,
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add ast/ddl.odin
git commit -m "feat(ast): add DDL statement types"
```

---

## Task 9: ast/node.odin — Node Tagged Union

**Files:**
- Modify: `ast/node.odin` (replace stub)

- [ ] **Step 1: Replace the stub with the full tagged union**

```odin
package ast

// Node is the central tagged union representing any SQL AST node.
// Uses Odin's discriminated union for exhaustive switch checking.
Node :: union {
	// Statements (DML)
	Select_Stmt,
	Insert_Stmt,
	Update_Stmt,
	Delete_Stmt,
	Truncate_Stmt,
	Explain_Stmt,
	Copy_Stmt,

	// Statements (DDL)
	Create_Table_Stmt,
	Create_Table_As_Stmt,
	Alter_Table_Stmt,
	Alter_Table_Cmd,
	Drop_Stmt,
	Create_Enum_Stmt,
	Alter_Enum_Stmt,
	Create_Function_Stmt,
	Function_Parameter,
	Drop_Function_Stmt,
	Create_Schema_Stmt,
	Drop_Schema_Stmt,
	Create_View_Stmt,
	Rename_Stmt,
	Comment_Stmt,
	Alter_Object_Schema_Stmt,
	Create_Extension_Stmt,
	Composite_Type_Stmt,
	Index_Stmt,
	Create_Seq_Stmt,
	Alter_Seq_Stmt,
	Grant_Stmt,
	Def_Elem,
	Role_Spec,
	Transaction_Stmt,
	Do_Stmt,
	Prepare_Stmt,
	Execute_Stmt,

	// Expressions
	A_Expr,
	A_Const,
	Bool_Expr,
	Func_Call,
	Type_Cast,
	Case_Expr,
	Case_When,
	Sub_Link,
	Coalesce_Expr,
	Null_Test,
	Boolean_Test,
	Row_Expr,
	A_Array_Expr,
	A_Indices,
	A_Indirection,
	Min_Max_Expr,
	Xml_Expr,
	Sql_Value_Function,
	Set_To_Default,
	Paren_Expr,

	// References
	Column_Ref,
	Param_Ref,
	Range_Var,
	Range_Subselect,
	Range_Function,
	Join_Expr,

	// Types / Names / Definitions
	Type_Name,
	Column_Def,
	Constraint,
	Res_Target,
	Alias,
	A_Star,
	Sort_By,
	Window_Def,
	Locking_Clause,
	Into_Clause,
	On_Conflict_Clause,
	Infer_Clause,
	Index_Elem,
	Multi_Assign_Ref,
	Grouping_Set,

	// Containers
	List,
	Raw_Stmt,

	// Scalars
	String_Node,
	Integer_Node,
	Float_Node,
	Boolean_Node,

	// CTE
	With_Clause,
	Common_Table_Expr,
}
```

- [ ] **Step 2: Verify the full ast package compiles**

Run: `odin check ast/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add ast/node.odin
git commit -m "feat(ast): define Node tagged union with all variants"
```

---

## Task 10: ast/tests/node_test.odin — AST Tests

**Files:**
- Create: `ast/tests/node_test.odin`

- [ ] **Step 1: Write tests for Node construction and pattern matching**

```odin
package ast_tests

import "core:testing"
import ast "../"

@(test)
test_node_select_stmt :: proc(t: ^testing.T) {
	sel := ast.Select_Stmt{
		op = .None,
	}
	node: ast.Node = sel
	_, ok := node.(ast.Select_Stmt)
	testing.expect(t, ok, "expected Select_Stmt variant")
}

@(test)
test_node_table_name :: proc(t: ^testing.T) {
	tn := ast.Table_Name{
		schema = "public",
		name   = "users",
	}
	testing.expect_value(t, tn.schema, "public")
	testing.expect_value(t, tn.name, "users")
}

@(test)
test_node_type_name :: proc(t: ^testing.T) {
	tn := ast.Type_Name{
		schema = "pg_catalog",
		name   = "int4",
	}
	testing.expect_value(t, tn.schema, "pg_catalog")
	testing.expect_value(t, tn.name, "int4")
}

@(test)
test_node_a_const_integer :: proc(t: ^testing.T) {
	c := ast.A_Const{
		type = .Integer,
		ival = 42,
	}
	node: ast.Node = c
	val, ok := node.(ast.A_Const)
	testing.expect(t, ok, "expected A_Const variant")
	testing.expect_value(t, val.type, ast.A_Const_Type.Integer)
	testing.expect_value(t, val.ival, i64(42))
}

@(test)
test_node_a_const_string :: proc(t: ^testing.T) {
	c := ast.A_Const{
		type = .String,
		sval = "hello",
	}
	node: ast.Node = c
	val, ok := node.(ast.A_Const)
	testing.expect(t, ok, "expected A_Const variant")
	testing.expect_value(t, val.sval, "hello")
}

@(test)
test_node_column_ref :: proc(t: ^testing.T) {
	s := ast.String_Node{sval = "id"}
	s_node: ast.Node = s

	cr := ast.Column_Ref{
		location = 10,
	}
	append(&cr.fields, &s_node)

	node: ast.Node = cr
	_, ok := node.(ast.Column_Ref)
	testing.expect(t, ok, "expected Column_Ref variant")
}

@(test)
test_node_switch :: proc(t: ^testing.T) {
	insert := ast.Insert_Stmt{}
	node: ast.Node = insert

	found := false
	#partial switch _ in node {
	case ast.Select_Stmt:
		testing.fail(t, "should not be Select_Stmt")
	case ast.Insert_Stmt:
		found = true
	}
	testing.expect(t, found, "expected Insert_Stmt branch to execute")
}

@(test)
test_constraint_types :: proc(t: ^testing.T) {
	c := ast.Constraint{
		contype = .Primary_Key,
		conname = "pk_users",
	}
	testing.expect_value(t, c.contype, ast.Constraint_Type.Primary_Key)
	testing.expect_value(t, c.conname, "pk_users")
}

@(test)
test_func_call :: proc(t: ^testing.T) {
	fc := ast.Func_Call{
		agg_star     = true,
		agg_distinct = false,
		location     = 0,
	}
	node: ast.Node = fc
	val, ok := node.(ast.Func_Call)
	testing.expect(t, ok, "expected Func_Call variant")
	testing.expect(t, val.agg_star, "expected agg_star true")
}
```

- [ ] **Step 2: Run the tests**

Run: `odin test ast/tests/`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add ast/tests/node_test.odin
git commit -m "test(ast): add Node tagged union tests"
```

---

## Task 11: pg_query/pg_query.odin — C FFI Bindings

**Files:**
- Create: `pg_query/pg_query.odin`

- [ ] **Step 1: Write the libpg_query C bindings**

```odin
package pg_query

import "core:c"

// Library path — built from source into vendor/libpg_query/lib/
when ODIN_OS == .Windows {
	LIB :: #config(PG_QUERY_LIB, "../vendor/libpg_query/lib/pg_query.lib")
} else {
	LIB :: #config(PG_QUERY_LIB, "../vendor/libpg_query/lib/libpg_query.a")
}

foreign import pg_query_lib {LIB}

// Error information from a failed parse
Parse_Error :: struct {
	message:   cstring,
	funcname:  cstring,
	filename:  cstring,
	lineno:    c.int,
	cursorpos: c.int,
	context:   cstring,
}

// Result of pg_query_parse — contains JSON AST
Parse_Result :: struct {
	parse_tree:    cstring,    // JSON AST string
	stderr_buffer: cstring,    // buffered stderr output
	error:         ^Parse_Error, // nil on success
}

// Result of pg_query_normalize
Normalize_Result :: struct {
	normalized_query: cstring,
	error:            ^Parse_Error,
}

// Result of pg_query_fingerprint
Fingerprint_Result :: struct {
	fingerprint:     c.uint64_t,
	fingerprint_str: cstring,
	stderr_buffer:   cstring,
	error:           ^Parse_Error,
}

// Result of pg_query_split_with_scanner
Split_Stmt :: struct {
	stmt_location: c.int,
	stmt_len:      c.int,
}

Split_Result :: struct {
	stmts:         [^]^Split_Stmt,
	n_stmts:       c.int,
	stderr_buffer: cstring,
	error:         ^Parse_Error,
}

@(default_calling_convention = "c")
foreign pg_query_lib {
	// Parse SQL and return JSON AST
	pg_query_parse :: proc(input: cstring) -> Parse_Result ---

	// Normalize query (replace constants with $N placeholders)
	pg_query_normalize :: proc(input: cstring) -> Normalize_Result ---

	// Compute query fingerprint
	pg_query_fingerprint :: proc(input: cstring) -> Fingerprint_Result ---

	// Split multi-statement SQL
	pg_query_split_with_scanner :: proc(input: cstring) -> Split_Result ---

	// Free results
	pg_query_free_parse_result      :: proc(result: Parse_Result) ---
	pg_query_free_normalize_result  :: proc(result: Normalize_Result) ---
	pg_query_free_fingerprint_result :: proc(result: Fingerprint_Result) ---
	pg_query_free_split_result      :: proc(result: Split_Result) ---
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check pg_query/ -vet -no-entry-point`
Expected: No errors (linker not invoked at check time)

- [ ] **Step 3: Commit**

```bash
git add pg_query/pg_query.odin
git commit -m "feat(pg_query): add libpg_query C FFI bindings"
```

---

## Task 12: pg_query/parse.odin — Higher-Level Parse Wrapper

**Files:**
- Create: `pg_query/parse.odin`

- [ ] **Step 1: Write the parse wrapper**

```odin
package pg_query

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:mem"

// Structured error info from a parse failure
Error_Info :: struct {
	message:   string,
	funcname:  string,
	filename:  string,
	lineno:    int,
	cursorpos: int,
	context:   string,
}

// A parsed statement with its location in the source
Parsed_Stmt :: struct {
	stmt_json: json.Value,  // the parsed statement as JSON
	location:  i32,          // byte offset in source
	length:    i32,          // byte length (0 = to end)
}

// Parse a SQL string and return the JSON AST as parsed statements.
// Caller must call destroy_parsed_stmts() when done.
parse :: proc(
	sql: string,
	allocator := context.allocator,
) -> (stmts: [dynamic]Parsed_Stmt, err: Maybe(Error_Info)) {
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	result := pg_query_parse(c_sql)
	defer pg_query_free_parse_result(result)

	// Check for parse errors
	if result.error != nil {
		e := result.error
		return {}, Error_Info{
			message   = _clone_cstring(e.message, allocator),
			funcname  = _clone_cstring(e.funcname, allocator),
			filename  = _clone_cstring(e.filename, allocator),
			lineno    = int(e.lineno),
			cursorpos = int(e.cursorpos),
			context   = _clone_cstring(e.context, allocator),
		}
	}

	if result.parse_tree == nil {
		return {}, nil
	}

	// Parse the JSON AST
	json_str := string(result.parse_tree)
	parsed, json_err := json.parse_string(json_str, allocator = allocator)
	if json_err != nil {
		return {}, Error_Info{
			message = fmt.aprintf("failed to parse libpg_query JSON output: %v", json_err, allocator = allocator),
		}
	}

	// Extract statements from {"version": N, "stmts": [...]}
	root, root_ok := parsed.(json.Object)
	if !root_ok {
		return {}, Error_Info{message = "expected JSON object from libpg_query"}
	}

	stmts_val, stmts_ok := root["stmts"]
	if !stmts_ok {
		return {}, nil  // no statements
	}

	stmts_arr, arr_ok := stmts_val.(json.Array)
	if !arr_ok {
		return {}, Error_Info{message = "expected stmts to be a JSON array"}
	}

	result_stmts := make([dynamic]Parsed_Stmt, 0, len(stmts_arr), allocator)

	for stmt_val in stmts_arr {
		stmt_obj, obj_ok := stmt_val.(json.Object)
		if !obj_ok {
			continue
		}

		ps := Parsed_Stmt{}

		if s, ok := stmt_obj["stmt"]; ok {
			ps.stmt_json = s
		}

		if loc, ok := stmt_obj["stmt_location"]; ok {
			if loc_int, lok := loc.(json.Integer); lok {
				ps.location = i32(loc_int)
			}
		}

		if slen, ok := stmt_obj["stmt_len"]; ok {
			if len_int, lok := slen.(json.Integer); lok {
				ps.length = i32(len_int)
			}
		}

		append(&result_stmts, ps)
	}

	return result_stmts, nil
}

// Normalize a SQL query (replace constants with $N).
normalize :: proc(sql: string, allocator := context.allocator) -> (string, Maybe(Error_Info)) {
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	result := pg_query_normalize(c_sql)
	defer pg_query_free_normalize_result(result)

	if result.error != nil {
		e := result.error
		return "", Error_Info{
			message = _clone_cstring(e.message, allocator),
		}
	}

	if result.normalized_query == nil {
		return "", nil
	}

	return strings.clone_from_cstring(result.normalized_query, allocator), nil
}

// Fingerprint a SQL query.
fingerprint :: proc(sql: string, allocator := context.allocator) -> (string, Maybe(Error_Info)) {
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	result := pg_query_fingerprint(c_sql)
	defer pg_query_free_fingerprint_result(result)

	if result.error != nil {
		e := result.error
		return "", Error_Info{
			message = _clone_cstring(e.message, allocator),
		}
	}

	if result.fingerprint_str == nil {
		return "", nil
	}

	return strings.clone_from_cstring(result.fingerprint_str, allocator), nil
}

// Helper: clone a cstring to a string, handling nil
_clone_cstring :: proc(cs: cstring, allocator: mem.Allocator) -> string {
	if cs == nil {
		return ""
	}
	return strings.clone_from_cstring(cs, allocator)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `odin check pg_query/ -vet -no-entry-point`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add pg_query/parse.odin
git commit -m "feat(pg_query): add high-level parse/normalize/fingerprint wrappers"
```

---

## Task 13: pg_query/tests — Parse Tests

**Files:**
- Create: `pg_query/tests/pg_query_test.odin`

These tests require the libpg_query library to be built (Task 1). They test actual SQL parsing.

- [ ] **Step 1: Write the parse tests**

```odin
package pg_query_tests

import "core:testing"
import "core:encoding/json"
import pg_query "../"

@(test)
test_parse_simple_select :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("SELECT 1")
	testing.expect(t, err == nil, "expected no error")
	testing.expect_value(t, len(stmts), 1)

	// The first statement should contain a SelectStmt
	stmt := stmts[0]
	obj, ok := stmt.stmt_json.(json.Object)
	testing.expect(t, ok, "expected JSON object")
	_, has_select := obj["SelectStmt"]
	testing.expect(t, has_select, "expected SelectStmt key")
}

@(test)
test_parse_create_table :: proc(t: ^testing.T) {
	sql := "CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT NOT NULL)"
	stmts, err := pg_query.parse(sql)
	testing.expect(t, err == nil, "expected no error")
	testing.expect_value(t, len(stmts), 1)

	obj, ok := stmts[0].stmt_json.(json.Object)
	testing.expect(t, ok, "expected JSON object")
	_, has_create := obj["CreateStmt"]
	testing.expect(t, has_create, "expected CreateStmt key")
}

@(test)
test_parse_multiple_statements :: proc(t: ^testing.T) {
	sql := "SELECT 1; SELECT 2; SELECT 3"
	stmts, err := pg_query.parse(sql)
	testing.expect(t, err == nil, "expected no error")
	testing.expect_value(t, len(stmts), 3)
}

@(test)
test_parse_insert :: proc(t: ^testing.T) {
	sql := "INSERT INTO users (name) VALUES ('test')"
	stmts, err := pg_query.parse(sql)
	testing.expect(t, err == nil, "expected no error")
	testing.expect_value(t, len(stmts), 1)

	obj, ok := stmts[0].stmt_json.(json.Object)
	testing.expect(t, ok, "expected JSON object")
	_, has_insert := obj["InsertStmt"]
	testing.expect(t, has_insert, "expected InsertStmt key")
}

@(test)
test_parse_error :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("SELCT 1")  // typo
	testing.expect(t, err != nil, "expected parse error")
	e := err.?
	testing.expect(t, len(e.message) > 0, "expected error message")
}

@(test)
test_parse_empty :: proc(t: ^testing.T) {
	stmts, err := pg_query.parse("")
	testing.expect(t, err == nil, "expected no error for empty input")
	testing.expect_value(t, len(stmts), 0)
}

@(test)
test_parse_statement_locations :: proc(t: ^testing.T) {
	sql := "SELECT 1; SELECT 2"
	stmts, err := pg_query.parse(sql)
	testing.expect(t, err == nil, "expected no error")
	testing.expect_value(t, len(stmts), 2)

	// First statement starts at 0
	testing.expect_value(t, stmts[0].location, i32(0))
	// Second statement starts after "; "
	testing.expect(t, stmts[1].location > 0, "second stmt should have non-zero location")
}

@(test)
test_normalize :: proc(t: ^testing.T) {
	result, err := pg_query.normalize("SELECT * FROM users WHERE id = 42 AND name = 'test'")
	testing.expect(t, err == nil, "expected no error")
	testing.expect(t, len(result) > 0, "expected normalized query")
	// Constants should be replaced with $N
}

@(test)
test_fingerprint :: proc(t: ^testing.T) {
	fp1, err1 := pg_query.fingerprint("SELECT * FROM users WHERE id = 1")
	testing.expect(t, err1 == nil, "expected no error")
	testing.expect(t, len(fp1) > 0, "expected fingerprint")

	// Same query with different constant should have same fingerprint
	fp2, err2 := pg_query.fingerprint("SELECT * FROM users WHERE id = 2")
	testing.expect(t, err2 == nil, "expected no error")
	testing.expect_value(t, fp1, fp2)
}
```

- [ ] **Step 2: Build libpg_query if not already done**

Run: `./scripts/build_libpg_query.sh`

- [ ] **Step 3: Run the tests**

Run: `odin test pg_query/tests/`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add pg_query/tests/pg_query_test.odin
git commit -m "test(pg_query): add SQL parsing integration tests"
```

---

## Summary

After completing all 13 tasks, we have:

- **pg/ package**: Extended with `Error` enum, `check_result`, and 14 typed value extraction procs
- **ast/ package**: Complete tagged union with ~80 variants across 5 files (enums, types, stmt, expr, ddl)
- **pg_query/ package**: C FFI bindings to libpg_query with high-level parse/normalize/fingerprint wrappers
- **Tests**: Node construction tests + SQL parsing integration tests

**Next plan** will cover: `ast/convert.odin` + `ast/translate.odin` (JSON → AST conversion), `ast/walk.odin` (AST traversal), and `ast/format.odin` (SQL formatting).
