# odin-sqlc: Full Port of sqlc to Odin (PostgreSQL)

## Overview

Port the entire [sqlc](https://sqlc.dev) SQL compiler from Go to Odin, targeting PostgreSQL. The tool reads SQL schema and query files, infers types, and generates type-safe Odin code that uses `pg/pg.odin` (libpq bindings) at runtime.

**Goal:** Full feature parity with go-sqlc for PostgreSQL, including all query command types (`:one`, `:many`, `:exec`, `:execresult`, `:execrows`, `:copyfrom`, `:batchexec`, `:batchmany`, `:batchone`), catalog-based and database-backed analysis, config file support, and CLI.

## Architecture

### Approach

Monolithic Odin project with packages mirroring go-sqlc's structure. Each package is independently testable and builds bottom-up.

### Memory Management Strategy

The tool (not the generated code) uses **arena allocators** for each compilation unit:
- One arena per `parse_catalog` call — holds the entire catalog lifetime
- One arena per `parse_queries` call — holds all query analysis results
- Temporary arena for each individual query analysis (freed after the query is processed)
- The codegen phase reads from existing allocations and writes to `strings.Builder`

Generated code follows Odin convention: procs that allocate take `allocator := context.allocator`.

### Package Structure

```
odin-sqlc/
├── pg/                  # libpq bindings (existing, extended)
│   ├── pg.odin          # existing C FFI bindings (144 functions)
│   ├── error.odin       # Error enum + check_result helper
│   └── value.odin       # typed value extraction from Result
│
├── pg_query/            # libpg_query C FFI bindings
│   ├── pg_query.odin    # foreign bindings to libpg_query C API
│   └── parse.odin       # higher-level parse wrapper (JSON → ast.Node)
│
├── ast/                 # SQL abstract syntax tree
│   ├── node.odin        # Node tagged union (~80-100 variants)
│   ├── stmt.odin        # statement structs (Select_Stmt, Insert_Stmt, etc.)
│   ├── expr.odin        # expression structs (A_Expr, Func_Call, etc.)
│   ├── ddl.odin         # DDL structs (Create_Table_Stmt, Alter_Table_Stmt, etc.)
│   ├── types.odin       # Table_Name, Type_Name, Func_Name, Column_Ref, etc.
│   ├── enums.odin       # AST enums (Set_Operation, Bool_Expr_Type, Func_Param_Mode, etc.)
│   ├── walk.odin        # AST traversal: walk, search, apply (replaces Go's astutils)
│   ├── convert.odin     # libpg_query JSON → ast.Node (generic node conversion)
│   ├── translate.odin   # DDL-specific translation with schema extraction logic
│   └── format.odin      # SQL formatting/printing from AST (dialect-aware)
│
├── source/              # source text manipulation
│   └── source.odin      # pluck, mutate, strip_comments, edit tracking
│
├── catalog/             # database schema representation
│   ├── catalog.odin     # Catalog struct, Build, Update
│   ├── schema.odin      # Schema, Table, Column types
│   ├── types.odin       # Enum, Composite_Type (Type union)
│   ├── func.odin        # Function, Argument types
│   ├── view.odin        # CREATE VIEW / CREATE TABLE AS handling
│   ├── pg_catalog.odin  # built-in pg_catalog types + functions (generated, ~40K lines)
│   ├── info_schema.odin # information_schema definitions (generated, ~4K lines)
│   └── extensions.odin  # extension loading (34 contrib extensions, generated)
│
├── config/              # sqlc.yaml/json configuration
│   ├── config.odin      # Config, SQL, Database, Override types + parsing
│   └── validate.odin    # config validation logic
│
├── metadata/            # query comment annotations
│   └── metadata.odin    # parse "-- name: X :cmd" annotations
│
├── named/               # named parameter handling
│   └── named.odin       # Param_Set, sqlc.arg(), sqlc.narg(), @param, sqlc.slice()
│
├── rewrite/             # AST rewriting
│   └── rewrite.odin     # named param → $N conversion, embed expansion, source edits
│
├── validate/            # sqlc-specific validation
│   └── validate.odin    # func_call, cmd, in-clause, insert_stmt, param_ref, param_style
│
├── migrations/          # migration file preprocessing
│   └── migrations.odin  # strip rollback statements (goose, sql-migrate, tern, dbmate)
│
├── inflection/          # name inflection
│   └── inflection.odin  # singular/plural conversion for struct names
│
├── multierr/            # error accumulation
│   └── multierr.odin    # collect multiple errors with file/line context
│
├── compiler/            # parse → catalog → analyze → type inference
│   ├── compiler.odin    # Compiler struct, ParseCatalog, ParseQueries
│   ├── parse.odin       # parseQuery: metadata extraction, analysis dispatch
│   ├── analyze.odin     # _analyzeQuery: type inference, column/param resolution
│   ├── resolve.odin     # resolveCatalogRefs, parameter type resolution
│   ├── output.odin      # outputColumns: compute query result columns
│   ├── query_catalog.odin # CTE/subquery table namespace
│   └── find_params.odin # AST walk to find parameter references
│
├── codegen/             # Odin code generation
│   ├── gen.odin         # main Generate proc: orchestrates pipeline
│   ├── query.odin       # query function code generation
│   ├── models.odin      # struct/enum model generation
│   ├── types.odin       # PostgreSQL → Odin type mapping
│   └── db.odin          # db helper code generation
│
└── cmd/                 # CLI entry point
    └── sqlc.odin        # main proc, arg parsing, command dispatch
```

## Component Design

### 1. pg/ Extensions

Extend the existing `pg/pg.odin` with error handling and value extraction.

**Error enum** (`pg/error.odin`):

```odin
Error :: enum {
    None,
    Bad_Response,
    Nonfatal_Error,
    Fatal_Error,
    Empty_Query,
    Pipeline_Aborted,
    Connection_Bad,
    Out_Of_Memory,
}
```

Derived from libpq's `Exec_Status` enum already defined in `pg.odin`. The `check_result` proc maps `Exec_Status` → `Error`.

**Value extraction** (`pg/value.odin`):

Typed extraction procs wrapping `pq.get_value` and `pq.get_is_null`:

- `get_i16`, `get_i32`, `get_i64` — integer extraction with text→int parsing
- `get_f32`, `get_f64` — float extraction
- `get_bool` — boolean extraction ("t"/"f" parsing)
- `get_string`, `get_bytes` — string/binary extraction with allocator parameter
- `get_maybe_*` variants — return `Maybe(T)` for nullable columns

All procs take `(res: Result, row: i32, col: i32)` and return `(T, bool)` or `Maybe(T)`.

### 2. pg_query/ — libpg_query Bindings

Bind to [libpg_query](https://github.com/pganalyze/libpg_query) C API via Odin foreign import.

**Architectural deviation from Go:** The Go version uses `pg_query_parse_protobuf()` which returns protobuf-serialized AST, then converts via auto-generated Go structs from `.proto` files. Odin lacks protobuf codegen tooling, so we deliberately use `pg_query_parse()` which returns a **JSON string** of the AST.

**Trade-offs of JSON approach:**
- **Pro:** No protobuf dependency; Odin has `core:encoding/json` built in
- **Pro:** JSON schema is stable and documented by the libpg_query project
- **Con:** JSON parsing is slower than protobuf deserialization (~2-5x)
- **Con:** JSON field names may differ slightly from protobuf field names — the libpg_query JSON output must be the source of truth, not the `.proto` files
- **Acceptable because:** SQL compilation is not a hot loop; parsing time is dominated by the actual SQL parsing in libpg_query, not serialization format

**C API surface:**

```odin
Parse_Result :: struct {
    parse_tree:    cstring,   // JSON AST string
    stderr_buffer: cstring,
    error:         ^Parse_Error,
}

Parse_Error :: struct {
    message:   cstring,
    funcname:  cstring,
    filename:  cstring,
    lineno:    c.int,
    cursorpos: c.int,
    context:   cstring,
}

Normalize_Result :: struct {
    normalized_query: cstring,
    error:            ^Parse_Error,
}

Fingerprint_Result :: struct {
    fingerprint:     u64,
    fingerprint_str: cstring,
    stderr_buffer:   cstring,
    error:           ^Parse_Error,
}

@(default_calling_convention = "c")
foreign pg_query_lib {
    pg_query_parse                  :: proc(input: cstring) -> Parse_Result ---
    pg_query_normalize              :: proc(input: cstring) -> Normalize_Result ---
    pg_query_fingerprint            :: proc(input: cstring) -> Fingerprint_Result ---
    pg_query_free_parse_result      :: proc(result: Parse_Result) ---
    pg_query_free_normalize_result  :: proc(result: Normalize_Result) ---
    pg_query_free_fingerprint_result :: proc(result: Fingerprint_Result) ---
}
```

**Higher-level wrapper:**

```odin
// Parses SQL string (may contain multiple statements).
// libpg_query handles multi-statement splitting natively via its JSON
// output: {"stmts": [{...}, {...}]}, so no separate SQL file splitter is needed.
// Returns one Raw_Stmt per statement.
parse :: proc(sql: string, allocator: mem.Allocator) -> ([]ast.Raw_Stmt, Parse_Error_Info)
```

**JSON AST format:** libpg_query returns JSON like:
```json
{
  "version": 170001,
  "stmts": [
    {
      "stmt": { "SelectStmt": { "targetList": [...], "fromClause": [...] } },
      "stmt_location": 0,
      "stmt_len": 42
    }
  ]
}
```

Each node is a JSON object with a single key (the node type name) containing the node's fields. This discriminated format maps directly to our tagged union dispatch.

### 3. ast/ — Tagged Union AST

Odin's tagged unions replace Go's 315 separate AST node type files with exhaustive compile-time switch checking.

**Node union** (~80-100 variants covering all PostgreSQL syntax):

Categories:
- **Statements:** `Select_Stmt`, `Insert_Stmt`, `Update_Stmt`, `Delete_Stmt`, `Raw_Stmt`
- **DDL:** `Create_Table_Stmt`, `Alter_Table_Stmt`, `Drop_Stmt`, `Create_Enum_Stmt`, `Alter_Enum_Stmt`, `Create_Function_Stmt`, `Drop_Function_Stmt`, `Create_Schema_Stmt`, `Drop_Schema_Stmt`, `Create_View_Stmt`, `Create_Table_As_Stmt`, `Rename_Stmt`, `Comment_Stmt`, `Alter_Type_Stmt`, `Alter_Object_Schema_Stmt`, `Create_Extension_Stmt`
- **Expressions:** `A_Expr`, `A_Const`, `Bool_Expr`, `Func_Call`, `Type_Cast`, `Case_Expr`, `Case_When`, `Sub_Link`, `Coalesce_Expr`, `Null_Test`, `Boolean_Test`, `Paren_Expr`
- **References:** `Column_Ref`, `Param_Ref`, `Range_Var`, `Range_Subselect`, `Range_Function`, `Join_Expr`
- **Types/Names:** `Type_Name`, `Table_Name`, `Func_Name`, `Column_Def`, `Constraint`, `Res_Target`, `Alias`
- **Containers:** `List`, `A_Array_Expr`, `Row_Expr`, `Sort_By`, `Window_Def`, `With_Clause`, `Common_Table_Expr`, `On_Conflict_Clause`

**AST enums** (`ast/enums.odin`):

```odin
Set_Operation :: enum { None, Union, Intersect, Except }

Bool_Expr_Type :: enum { And, Or, Not }

A_Expr_Kind :: enum { Normal, Op, Like, ILike, Similar, Between, Not_Between, In, Not_In }

Sub_Link_Type :: enum { Exists, All, Any, Row_Compare, Expr, Multiexpr, Array }

Func_Param_Mode :: enum { In, Out, In_Out, Variadic, Table, Default }

Drop_Behavior :: enum { Restrict, Cascade }

Null_Test_Type :: enum { Is_Null, Is_Not_Null }

// ... additional enums as needed
```

**Key struct patterns:**

```odin
Select_Stmt :: struct {
    target_list:   [dynamic]^Node,
    from_clause:   [dynamic]^Node,
    where_clause:  ^Node,
    group_clause:  [dynamic]^Node,
    having_clause: ^Node,
    order_clause:  [dynamic]^Node,
    limit_count:   ^Node,
    limit_offset:  ^Node,
    op:            Set_Operation,
    larg:          ^Select_Stmt,
    rarg:          ^Select_Stmt,
    location:      i32,
}

Table_Name :: struct {
    catalog: string,
    schema:  string,
    name:    string,
}

Type_Name :: struct {
    catalog:      string,
    schema:       string,
    name:         string,
    array_bounds: [dynamic]^Node,
    location:     i32,
}
```

**AST Traversal** (`ast/walk.odin`):

Replaces Go's `internal/sql/astutils/` (walk.go: 2200 lines, rewrite.go: 1271 lines). In Odin, AST traversal is a recursive `#partial switch` on the `Node` tagged union:

```odin
// Visitor callback — return false to stop walking
Visitor :: #type proc(node: ^Node, user_data: rawptr) -> bool

// Walk the AST depth-first, calling visitor for each node
walk :: proc(node: ^Node, visitor: Visitor, user_data: rawptr)

// Search for a node matching a predicate
search :: proc(node: ^Node, pred: proc(^Node) -> bool) -> ^Node

// Apply a transformation to every node (in-place mutation)
apply :: proc(node: ^Node, transform: proc(^Node) -> ^Node)
```

The walk proc contains a large `#partial switch` that recurses into each variant's child nodes. This replaces Go's generated walker which has a case per AST type.

**Two-layer translation** from libpg_query JSON:

1. **`ast/convert.odin`** — Generic node conversion. Mechanical field-by-field conversion for expressions, DML, and most node types. Dispatches on the JSON key string to type-specific conversion procs. (~2000-3000 lines)

2. **`ast/translate.odin`** — DDL-specific translation with semantic logic. Handles `CREATE TABLE` (extracting primary keys, constraints, column definitions), `ALTER TABLE`, `CREATE ENUM`, `RENAME`, `COMMENT ON`, etc. This layer contains significant logic beyond simple field mapping, including:
   - Extracting NOT NULL from column constraints
   - Identifying primary key columns
   - Parsing relation names from node lists
   - Handling `ALTER TABLE` subcommands
   - Processing `CREATE TABLE ... AS` and `CREATE VIEW`

The split mirrors Go's `convert.go` (generic) + `translate()` in `parse.go` (DDL-specific).

**SQL Formatting** (`ast/format.odin`):

Dialect-aware SQL output from AST nodes. Used by:
- Query rewriting (named param substitution, star expansion)
- Error messages (showing the offending SQL)
- Debug output

The formatter walks the AST and writes to a `strings.Builder` with PostgreSQL quoting rules (double-quote identifiers, `$N` parameters). Each node type has a format case in a `#partial switch`. Not all nodes need formatting — only those involved in query rewriting and output.

**Reserved keywords** are handled via a lookup set used for identifier quoting in the formatter.

### 4. source/ — Source Text Manipulation

Ports Go's `internal/source/` package. Handles source-level text operations:

```odin
// An edit to the source text (position + replacement)
Edit :: struct {
    location: i32,  // byte offset in original source
    old_len:  i32,  // bytes to replace
    new_text: string, // replacement text
}

// Extract the SQL text for a specific statement from a multi-statement file
pluck :: proc(source: string, location: i32, length: i32) -> string

// Apply accumulated edits to source text (for parameter rewriting, star expansion)
mutate :: proc(source: string, edits: []Edit, allocator: mem.Allocator) -> string

// Remove SQL comments from query text (for final output)
strip_comments :: proc(source: string, allocator: mem.Allocator) -> string

// Extract comment text for metadata parsing
cleaned_comments :: proc(source: string) -> []string

// Get line number from byte offset (for error reporting)
line_number :: proc(source: string, offset: i32) -> i32
```

### 5. catalog/ — Schema Representation

Direct port of Go's catalog types.

**Catalog:**

```odin
Catalog :: struct {
    name:            string,
    default_schema:  string,
    schemas:         [dynamic]^Schema,
    search_path:     [dynamic]string,
    extensions:      map[string]bool,
    load_extension:  proc(name: string) -> ^Schema,  // callback for contrib extensions
}
```

**Schema, Table, Column:**

```odin
Schema :: struct {
    name:    string,
    tables:  [dynamic]^Table,
    types:   [dynamic]Type,
    funcs:   [dynamic]^Function,
    comment: string,
}

Table :: struct {
    rel:     ast.Table_Name,
    columns: [dynamic]^Column,
    comment: string,
}

Column :: struct {
    name:        string,
    type_name:   ast.Type_Name,
    is_not_null: bool,
    is_unsigned: bool,
    is_array:    bool,
    array_dims:  int,
    comment:     string,
    length:      Maybe(int),
}
```

**Type system:**

```odin
Type :: union {
    Enum,
    Composite_Type,
}

Enum :: struct {
    name:    string,
    vals:    [dynamic]string,
    comment: string,
}

Composite_Type :: struct {
    name:    string,
    comment: string,
}

Function :: struct {
    name:                 string,
    args:                 [dynamic]^Argument,
    return_type:          Maybe(ast.Type_Name),
    return_type_nullable: bool,
    comment:              string,
}

Argument :: struct {
    name:        string,
    type_name:   ^ast.Type_Name,
    has_default: bool,
    mode:        ast.Func_Param_Mode,
}
```

**Catalog update** handles DDL AST nodes via `#partial switch`:
- CREATE/ALTER/DROP TABLE
- CREATE/ALTER/DROP TYPE (enum, composite)
- CREATE/DROP FUNCTION
- CREATE/DROP SCHEMA
- CREATE VIEW, CREATE TABLE AS
- CREATE EXTENSION (invokes `load_extension` callback)
- RENAME operations
- COMMENT ON operations

**View/CREATE TABLE AS handling** (`catalog/view.odin`):

Views and `CREATE TABLE AS` require computing output columns from a SELECT statement — a circular dependency between catalog and compiler. Resolution: the catalog accepts a `Column_Generator` callback:

```odin
Column_Generator :: #type proc(catalog: ^Catalog, select_stmt: ^ast.Select_Stmt) -> [dynamic]^Column

// Called during catalog update when processing CREATE VIEW / CREATE TABLE AS
update_with_column_gen :: proc(c: ^Catalog, stmt: ast.Node, col_gen: Column_Generator) -> Error
```

The compiler provides the `Column_Generator` implementation, breaking the circular dependency.

**pg_catalog.odin** (~40,000 lines, generated):

Built-in PostgreSQL system catalog definitions. This file is **generated** by a code generator tool (not hand-written), sourced from either:
- The Go `pg_catalog.go` / `information_schema.go` files (translating Go → Odin)
- PostgreSQL system tables directly via `pg_dump` of system catalogs

Contains all pg_catalog types (bool, int2, int4, int8, float4, float8, text, bytea, uuid, json, jsonb, timestamp, date, interval, numeric, etc.) and all pg_catalog functions (now(), count(), sum(), avg(), etc.).

A separate `gen_pg_catalog/` tool will produce this file. The tool reads the Go source and emits Odin.

**info_schema.odin** (~4,000 lines, generated):

information_schema definitions, also generated.

**extensions.odin** (generated):

Definitions for 34 PostgreSQL contrib extensions (adminpack, pgcrypto, uuid-ossp, hstore, ltree, pg_trgm, citext, etc.). In Go, these total ~9,164 lines in `internal/engine/postgresql/extension/`. The `load_extension` callback on `Catalog` looks up extension schemas from this generated data when it encounters `CREATE EXTENSION` statements.

### 6. config/ — Configuration

Supports both v1 and v2 config formats (matching Go). Only v2 is recommended for new projects.

**Config types:**

```odin
Config :: struct {
    version:   string,           // "1" or "2"
    sql:       [dynamic]SQL,
    plugins:   [dynamic]Plugin,
    rules:     [dynamic]Rule,
    overrides: Overrides,        // global type overrides
}

SQL :: struct {
    name:                   string,
    engine:                 Engine,
    schema:                 [dynamic]string,
    queries:                [dynamic]string,
    database:               Maybe(Database),
    strict_function_checks: bool,
    strict_order_by:        bool,       // default true in v2
    gen:                    SQL_Gen,
    codegen:                [dynamic]Codegen,
    rules:                  [dynamic]string,
    analyzer:               Analyzer_Config,
}

Engine :: enum {
    PostgreSQL,
}

Database :: struct {
    uri:     string,
    managed: bool,
}

SQL_Gen :: struct {
    odin: Maybe(Odin_Gen_Options),
}

Odin_Gen_Options :: struct {
    package_name: string,
    out:          string,
    emit_enums:   bool,       // default true
}

// Type overrides — allows users to map SQL types to custom Odin types
Override :: struct {
    db_type:     string,           // e.g. "uuid", "timestamptz"
    odin_type:   Override_Type,    // custom Odin type to use
    column:      string,           // optional: specific column ("table.column")
    nullable:    bool,             // override applies to nullable variant
}

Override_Type :: struct {
    import_path: string,   // e.g. "my_project/types"
    package_name: string,  // e.g. "types"
    type_name:   string,   // e.g. "UUID"
}

Overrides :: struct {
    overrides: [dynamic]Override,
}

Analyzer_Config :: struct {
    database: Analyzer_Database,
}

// Supports three states: null (disabled), true (enabled), "only" (database-only mode)
Analyzer_Database :: struct {
    enabled: bool,
    is_only: bool,
}
```

**Parsing strategy:**
- JSON configs via `core:encoding/json`
- YAML support: bind to `libyaml` C library, or require JSON-only configs initially and add YAML later

### 7. metadata/ — Query Annotations

Parse SQL comment annotations following sqlc convention:

```
-- name: QueryName :command
```

**Types:**

```odin
Metadata :: struct {
    name:          string,
    cmd:           Command,
    comments:      [dynamic]string,
    params:        map[string]string,    // @param annotations
    flags:         map[string]bool,      // @flag annotations
    rule_skiplist: map[string]bool,      // @sqlc-vet-disable rules
    filename:      string,
}

Command :: enum {
    One,          // :one        — returns single row
    Many,         // :many       — returns []T
    Exec,         // :exec       — no return value
    Exec_Result,  // :execresult — returns result metadata
    Exec_Rows,    // :execrows   — returns rows affected count
    Copy_From,    // :copyfrom   — bulk insert
    Batch_Exec,   // :batchexec  — batch execute
    Batch_Many,   // :batchmany  — batch many results
    Batch_One,    // :batchone   — batch single result
}
```

Note: `:execlastid` exists in Go but is MySQL-specific. Not included in this PostgreSQL-only port.

**Parsing procs:**
- `parse_query_name_and_type(comment: string) -> (string, Command, bool)` — validates name as valid identifier, validates command from known list
- `parse_comment_flags(comments: []string) -> (params, flags, skiplist)` — parses `@param`, `@sqlc-vet-disable`, and other `@` annotations

**Error messages** reference the string forms for user-facing output (e.g., `"missing query type, expected one of :one, :many, :exec, ..."`).

### 8. named/ — Named Parameter Handling

Ports Go's `internal/sql/named/` package. Handles:

- `sqlc.arg('name')` / `sqlc.arg(name)` function syntax
- `sqlc.narg('name')` — nullable named arg
- `@param_name` — shorthand named parameter syntax
- `sqlc.slice('name')` — dynamic IN clause expansion

```odin
Param :: struct {
    name:        string,
    is_nullable: bool,     // from sqlc.narg() or @param annotation
    is_slice:    bool,     // from sqlc.slice()
}

// Set of named parameters discovered in a query, with nullability tracking
Param_Set :: struct {
    params: map[string]Param,
}

// Check if a Func_Call node is a sqlc.arg() / sqlc.narg() / sqlc.slice() call
is_named_param_func :: proc(node: ^ast.Func_Call) -> bool
is_named_param_sign :: proc(node: ^ast.A_Expr) -> bool  // @param syntax

// Extract the parameter name from a sqlc.arg() call or @param expression
extract_param_name :: proc(node: ^ast.Node) -> (string, bool)
```

### 9. rewrite/ — AST Rewriting

Ports Go's `internal/sql/rewrite/` package.

```odin
// Replace sqlc.arg(name) / @name with $N positional parameters.
// Returns source edits and the parameter mapping.
named_parameters :: proc(
    raw: ^ast.Raw_Stmt,
    source: string,
    param_set: ^named.Param_Set,
) -> (edits: [dynamic]source.Edit, params: [dynamic]named.Param)

// Expand embedded table references in result columns
expand_embeds :: proc(columns: [dynamic]^compiler.Column) -> [dynamic]^compiler.Column
```

### 10. validate/ — sqlc-Specific Validation

Ports Go's `internal/sql/validate/` package.

```odin
// Validate sqlc.* function calls (arg, narg, slice, embed) are used correctly
validate_func_call :: proc(catalog: ^catalog.Catalog, call: ^ast.Func_Call) -> Maybe(Error)

// Validate command type is compatible with statement type
validate_cmd :: proc(cmd: metadata.Command, stmt: ^ast.Node) -> Maybe(Error)

// Validate IN clause usage with sqlc.slice()
validate_in :: proc(expr: ^ast.A_Expr) -> Maybe(Error)

// Validate INSERT statement structure for :copyfrom
validate_insert_stmt :: proc(stmt: ^ast.Insert_Stmt, cmd: metadata.Command) -> Maybe(Error)

// Validate parameter references ($1, $2, ...) are consistent
validate_param_ref :: proc(refs: []Param_Ref) -> Maybe(Error)

// Validate parameter style consistency (don't mix $N with ?)
validate_param_style :: proc(refs: []Param_Ref) -> Maybe(Error)
```

### 11. migrations/ — Migration Preprocessing

Ports Go's `internal/migrations/` package.

```odin
// Remove rollback/down sections from migration files before parsing.
// Supports goose, sql-migrate, tern, dbmate marker formats.
remove_rollback_statements :: proc(source: string, allocator: mem.Allocator) -> string
```

Recognizes markers like:
- `-- +goose Down` / `-- +goose Up`
- `-- +migrate Down` / `-- +migrate Up`
- `---- create above / drop below ----` (tern)
- `-- migrate:down` / `-- migrate:up` (dbmate)

### 12. inflection/ — Name Inflection

Ports Go's `internal/inflection/` package.

```odin
// Convert plural table name to singular struct name
// "authors" → "Author", "categories" → "Category"
singular :: proc(name: string) -> string

// Convert singular to plural (less commonly needed)
plural :: proc(name: string) -> string
```

### 13. multierr/ — Error Accumulation

Ports Go's `internal/multierr/` package. Collects multiple errors with file/line context rather than failing on the first error. This is important for user experience — sqlc reports all errors across all files.

```odin
Multi_Error :: struct {
    errors: [dynamic]Error_Entry,
}

Error_Entry :: struct {
    filename: string,
    line:     i32,
    column:   i32,
    message:  string,
    source:   string,   // the SQL line that caused the error
}

// Add an error to the collection
add :: proc(me: ^Multi_Error, entry: Error_Entry)

// Check if any errors were collected
has_errors :: proc(me: ^Multi_Error) -> bool

// Format all errors for display (file:line:col: message)
format :: proc(me: ^Multi_Error, allocator: mem.Allocator) -> string
```

### 14. compiler/ — Query Compilation

The core analysis engine. Ports Go's compiler package.

**Compiler struct:**

```odin
Compiler :: struct {
    catalog:           ^catalog.Catalog,
    config:            config.SQL,
    queries:           [dynamic]^Query,
    errors:            multierr.Multi_Error,
    database_only_mode: bool,
}

Query :: struct {
    sql:               string,
    metadata:          metadata.Metadata,
    columns:           [dynamic]^Column,
    params:            [dynamic]Parameter,
    insert_into_table: Maybe(ast.Table_Name),
    raw_stmt:          ^ast.Raw_Stmt,
}

Column :: struct {
    name:           string,
    original_name:  string,
    data_type:      string,
    not_null:       bool,
    is_array:       bool,
    array_dims:     int,
    comment:        string,
    length:         Maybe(int),
    is_func_call:   bool,
    is_named_param: bool,                // from named parameter system
    is_sqlc_slice:  bool,
    scope:          string,              // column scope for ambiguity resolution
    table:          Maybe(ast.Table_Name),
    table_alias:    string,
    type_name:      Maybe(ast.Type_Name),
    embed_table:    Maybe(ast.Table_Name),
}

Parameter :: struct {
    number: int,
    column: ^Column,
}

Result :: struct {
    catalog: ^catalog.Catalog,
    queries: [dynamic]^Query,
}
```

**Pipeline procs:**

```odin
// Create compiler from config
new_compiler :: proc(conf: config.SQL, allocator: mem.Allocator) -> (^Compiler, multierr.Multi_Error)

// Parse schema files and build catalog
parse_catalog :: proc(c: ^Compiler, schema_paths: []string) -> multierr.Multi_Error

// Parse query files, analyze, and resolve types
parse_queries :: proc(c: ^Compiler, query_paths: []string) -> multierr.Multi_Error

// Get compilation result
result :: proc(c: ^Compiler) -> ^Result
```

**Analysis flow** (same three paths as Go):

1. Read schema/query files from disk
2. Preprocess migrations: `migrations.remove_rollback_statements()`
3. Parse SQL via `pg_query.parse()` (returns multiple statements)
4. For schemas: update catalog with each DDL statement
5. For queries:
   a. Extract source text via `source.pluck()`
   b. Parse metadata from comments via `metadata.parse_query_name_and_type()`
   c. Validate sqlc-specific functions via `validate.*`
   d. Find parameter references via `find_params` (AST walk)
   e. Rewrite named parameters via `rewrite.named_parameters()`
   f. Build query catalog for CTEs/subqueries
   g. Resolve parameter types from catalog via `resolve.resolve_catalog_refs()`
   h. Compute output columns via `output.output_columns()` (expand `SELECT *`, `RETURNING *`)
   i. Apply source edits via `source.mutate()`
   j. Strip comments from final SQL via `source.strip_comments()`
   k. Return `Query` with fully typed columns and parameters
6. Validate no duplicate query names
7. Accumulate all errors via `multierr`

### 15. codegen/ — Odin Code Generation

Generates Odin source files from the compiler `Result`.

**Output files:**
- `models.odin` — struct and enum type definitions
- `query.sql.odin` (per source file) — query constants + functions
- `db.odin` — connection helper type (optional)

**Type mapping** (PostgreSQL → Odin):

| PostgreSQL | Odin (NOT NULL) | Odin (nullable) |
|---|---|---|
| serial, int4, integer | `i32` | `Maybe(i32)` |
| bigserial, int8, bigint | `i64` | `Maybe(i64)` |
| smallserial, int2, smallint | `i16` | `Maybe(i16)` |
| real, float4 | `f32` | `Maybe(f32)` |
| double precision, float8 | `f64` | `Maybe(f64)` |
| boolean, bool | `bool` | `Maybe(bool)` |
| text, varchar, char, name, citext | `string` | `Maybe(string)` |
| bytea | `[]byte` | `Maybe([]byte)` |
| uuid | `[16]byte` | `Maybe([16]byte)` |
| json, jsonb | `[]byte` | `Maybe([]byte)` |
| timestamp, timestamptz | `i64` | `Maybe(i64)` |
| date | `i32` | `Maybe(i32)` |
| time, timetz | `i64` | `Maybe(i64)` |
| interval | `i64` | `Maybe(i64)` |
| numeric, money | `string` | `Maybe(string)` |
| inet, cidr | `string` | `Maybe(string)` |
| macaddr | `string` | `Maybe(string)` |
| enum types | generated enum | `Maybe(Enum_Type)` |
| void | — | — |

Type overrides from config are checked first. If an override matches, its `Override_Type` is used instead of the default mapping.

**Generated code patterns:**

`:one` — single row:
```odin
get_author :: proc(conn: pq.Conn, id: i64) -> (Author, pq.Error) {
    // exec_params with parameter serialization
    // check_result
    // extract single row fields
    // return struct, .None
}
```

`:many` — multiple rows:
```odin
list_authors :: proc(conn: pq.Conn, allocator := context.allocator) -> ([]Author, pq.Error) {
    // exec query
    // check_result
    // iterate n_tuples, extract each row
    // return slice, .None
}
```

`:exec` — no return:
```odin
delete_author :: proc(conn: pq.Conn, id: i64) -> pq.Error {
    // exec_params
    // check_result
    // return error
}
```

`:execresult` — result metadata:
```odin
update_authors :: proc(conn: pq.Conn, name: string) -> (pq.Result, pq.Error) {
    // exec_params
    // check_result
    // return raw result (caller must clear), error
}
```

`:execrows` — rows affected:
```odin
delete_old_authors :: proc(conn: pq.Conn) -> (i64, pq.Error) {
    // exec
    // check_result
    // parse cmd_tuples for affected count
    // return count, error
}
```

`:copyfrom` — bulk insert via COPY protocol:
```odin
bulk_insert_authors :: proc(conn: pq.Conn, authors: []Author) -> pq.Error {
    // put_copy_data for each row (tab-delimited text format)
    // put_copy_end
    // check_result
}
```

`:batchexec` / `:batchone` / `:batchmany` — pipeline mode:
```odin
// Uses libpq pipeline mode (pq.enter_pipeline_mode / pq.send_query_params / pq.pipeline_sync)
batch_create_authors :: proc(conn: pq.Conn, params: []Create_Author_Params) -> pq.Error {
    pq.enter_pipeline_mode(conn)
    defer pq.exit_pipeline_mode(conn)
    for p in params {
        // send_query_params for each batch item
    }
    pq.pipeline_sync(conn)
    // collect results
}
```

**Code generation approach:** Procedural string building using `strings.Builder`, not templates. Odin doesn't have a text/template equivalent, and procedural generation is simpler to debug and test.

### 16. cmd/ — CLI

**Commands:**
- `sqlc generate` — parse config, compile SQL, generate Odin code
- `sqlc compile` — parse and validate only (no codegen)
- `sqlc init` — create starter `sqlc.json`
- `sqlc version` — print version

**Entry point:**

```odin
main :: proc() {
    args := os.args
    if len(args) < 2 {
        usage()
        return
    }

    cmd := args[1]
    cmd_args := args[2:] if len(args) > 2 else []string{}

    switch cmd {
    case "generate": cmd_generate(cmd_args)
    case "compile":  cmd_compile(cmd_args)
    case "init":     cmd_init(cmd_args)
    case "version":  cmd_version()
    case:            usage()
    }
}
```

## Build Order (Sub-Projects)

Each sub-project gets its own plan → implementation → test cycle:

1. **pg/ extensions** — Error enum, value extraction helpers
2. **pg_query/** — libpg_query C bindings, JSON parse wrapper
3. **ast/ types** — Node tagged union, all struct types, AST enums
4. **ast/ convert + translate** — libpg_query JSON → ast.Node (two-layer translation)
5. **ast/ walk + format** — AST traversal and SQL formatting
6. **source/** — Source text manipulation (pluck, mutate, strip_comments)
7. **catalog/** — Catalog, Schema, Table, Column, Type, Function, View
8. **catalog/ generated files** — pg_catalog, info_schema, extensions (code generator tool)
9. **config/** — Config parsing (JSON, later YAML) with overrides
10. **metadata/** — Query annotation parsing
11. **named/ + rewrite/ + validate/** — Named params, AST rewriting, validation
12. **migrations/** — Migration file preprocessing
13. **inflection/** — Name inflection
14. **multierr/** — Error accumulation
15. **compiler/** — Full compilation pipeline
16. **codegen/** — Odin code generation
17. **cmd/** — CLI entry point
18. **End-to-end testing** — Real PostgreSQL integration tests

## Key Design Decisions

1. **libpg_query via C FFI** — reuse PostgreSQL's own parser rather than writing one
2. **JSON AST (deliberate deviation from Go)** — Go uses protobuf; Odin uses JSON via `core:encoding/json` because protobuf codegen for Odin does not exist. Performance is acceptable since SQL compilation is not a hot loop.
3. **Tagged unions for AST** — idiomatic Odin, exhaustive switch checking, single union vs 315 Go files
4. **`Maybe(T)` for nullability** — replaces Go's `sql.Null*` types
5. **`pq.Error` enum** — generated functions return error enum (default `.None`), not raw Result
6. **Procedural codegen** — `strings.Builder` instead of templates
7. **Allocator parameters** — generated functions that allocate follow Odin convention
8. **Arena allocators** — tool internals use arenas for compilation unit lifetimes
9. **PostgreSQL only** — no MySQL/SQLite for initial port (can be added later)
10. **Generated catalog files** — pg_catalog (~40K lines), info_schema (~4K lines), and extensions (~9K lines) are produced by a code generator tool, not hand-written
11. **Column_Generator callback** — breaks circular dependency between catalog and compiler for CREATE VIEW / CREATE TABLE AS

## Feature Parity Checklist

All features from go-sqlc for PostgreSQL:

- [ ] Parse SQL schemas (CREATE TABLE, ALTER TABLE, CREATE TYPE, CREATE VIEW, CREATE EXTENSION, etc.)
- [ ] Parse SQL queries with metadata annotations
- [ ] All command types: `:one`, `:many`, `:exec`, `:execresult`, `:execrows`, `:copyfrom`, `:batchexec`, `:batchmany`, `:batchone`
- [ ] Type inference from catalog
- [ ] Named parameters (`sqlc.arg()`, `sqlc.narg()`, `@param`)
- [ ] `sqlc.slice()` for dynamic IN clauses
- [ ] SELECT * expansion
- [ ] RETURNING * expansion
- [ ] CTE (WITH clause) support
- [ ] Enum type generation
- [ ] Composite type handling
- [ ] Array type support
- [ ] Nullable column detection (NOT NULL, PRIMARY KEY, etc.)
- [ ] Custom type overrides in config
- [ ] Multiple schema support
- [ ] Extension support (pg_catalog, information_schema, 34 contrib extensions)
- [ ] Error accumulation (report all errors, not just first)
- [ ] Database-backed analysis mode (query live PostgreSQL for types)
- [ ] Database-only analysis mode
- [ ] Migration file preprocessing (goose, sql-migrate, tern, dbmate)
- [ ] Name inflection (plural table → singular struct)
- [ ] Config file support (JSON, later YAML) with v1 and v2 formats
- [ ] CLI with generate, compile, init, version commands
- [ ] Reserved keyword handling for identifier quoting
- [ ] Batch operations via PostgreSQL pipeline mode
