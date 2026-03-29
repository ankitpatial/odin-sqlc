package config

import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:path/filepath"
import "core:slice"

VERSION :: "1"

// Naming style for generated type names (structs, enums).
// Proc names are always snake_case.
Naming :: enum {
	pascal,       // "ProductCreateParams" (default)
	pascal_snake, // "Product_Create_Params"
}

Odin_Gen :: struct {
	package_name: string `json:"package"`,
	out:          string `json:"out"`,
	naming:       Naming `json:"naming"`,
}

Gen :: struct {
	odin: Maybe(Odin_Gen) `json:"odin"`,
}

SQL :: struct {
	name:    string `json:"name"`,
	schema:  Paths  `json:"schema"`,
	queries: Paths  `json:"queries"`,
	engine:  string `json:"engine"`,
	gen:     Gen    `json:"gen"`,
}

// Paths can be a single string or array of strings in JSON.
// We store as [dynamic]string internally.
Paths :: distinct [dynamic]string

Config :: struct {
	version: string       `json:"version"`,
	sql:     [dynamic]SQL `json:"sql"`,
}

Error :: enum {
	None,
	File_Not_Found,
	Parse_Error,
	Invalid_Version,
	No_SQL_Entries,
	Missing_Schema,
	Missing_Queries,
	Missing_Engine,
}

// Default config file name.
CONFIG_FILE :: "sqld.json"

// Find and load config from the given path or default.
load :: proc(path: string = "", allocator := context.allocator) -> (Config, Error) {
	file_path := path if len(path) > 0 else CONFIG_FILE

	data, read_err := os.read_entire_file(file_path, allocator)
	if read_err != nil {
		return {}, .File_Not_Found
	}

	return parse(data, allocator)
}

// Parse config from JSON bytes.
parse :: proc(data: []byte, allocator := context.allocator) -> (Config, Error) {
	cfg: Config

	err := json.unmarshal(data, &cfg, allocator = allocator)
	if err != nil {
		return {}, .Parse_Error
	}

	// Validate
	if cfg.version != VERSION {
		return cfg, .Invalid_Version
	}

	if len(cfg.sql) == 0 {
		return cfg, .No_SQL_Entries
	}

	for sql in cfg.sql {
		if len(sql.schema) == 0 {
			return cfg, .Missing_Schema
		}
		if len(sql.queries) == 0 {
			return cfg, .Missing_Queries
		}
		if len(sql.engine) == 0 {
			return cfg, .Missing_Engine
		}
	}

	return cfg, .None
}

// Format an error for display.
error_message :: proc(err: Error) -> string {
	switch err {
	case .None:            return ""
	case .File_Not_Found:  return "config file not found (run 'sqld init' to create one)"
	case .Parse_Error:     return "failed to parse config file as JSON"
	case .Invalid_Version: return fmt.aprintf("unsupported config version (expected \"%s\")", VERSION)
	case .No_SQL_Entries:  return "config has no 'sql' entries"
	case .Missing_Schema:  return "sql entry missing 'schema' field"
	case .Missing_Queries: return "sql entry missing 'queries' field"
	case .Missing_Engine:  return "sql entry missing 'engine' field"
	}
	return "unknown error"
}

// Expand glob patterns in paths to sorted file lists.
// e.g. "schema/*.sql" → ["schema/0001_city.sql", "schema/0002_venue.sql"]
expand_paths :: proc(paths: Paths, allocator := context.allocator) -> ([dynamic]string, bool) {
	result := make([dynamic]string, 0, len(paths) * 4, allocator)

	for pattern in paths {
		// Check if it contains glob characters
		if strings.contains_any(pattern, "*?[") {
			matches, g_err := filepath.glob(pattern, allocator)
			if g_err != nil || matches == nil {
				// Try as literal path
				if os.exists(pattern) {
					append(&result, strings.clone(pattern, allocator))
				} else {
					fmt.eprintf("error: no files match pattern '%s'\n", pattern)
					return {}, false
				}
				continue
			}
			// Sort for deterministic ordering (important for schema migrations)
			slice.sort(matches[:])
			for m in matches {
				append(&result, m)
			}
		} else {
			if !os.exists(pattern) {
				fmt.eprintf("error: file not found '%s'\n", pattern)
				return {}, false
			}
			append(&result, strings.clone(pattern, allocator))
		}
	}

	return result, true
}

// Read all SQL files matching the paths (supports globs).
read_sql_files :: proc(paths: Paths, allocator := context.allocator) -> (string, bool) {
	buf := strings.builder_make(allocator)

	for path in paths {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintf("error: cannot read file '%s'\n", path)
			return "", false
		}
		strings.write_string(&buf, string(data))
		strings.write_byte(&buf, '\n')
	}

	return strings.to_string(buf), true
}
