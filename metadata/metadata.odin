package metadata

import "core:strings"

Command :: enum {
	One,         // :one        — returns single row
	Many,        // :many       — returns []T
	Exec,        // :exec       — no return value
	Exec_Result, // :execresult — returns result metadata
	Exec_Rows,   // :execrows   — returns rows affected count
}

Metadata :: struct {
	name:     string,
	cmd:      Command,
	comments: [dynamic]string,
	filename: string,
}

// Parse a single comment line for "-- name: QueryName :cmd".
// Returns (name, cmd, ok).
parse_name_and_cmd :: proc(line: string) -> (string, Command, bool) {
	trimmed := strings.trim_space(line)

	// Must start with "-- name:" (case-sensitive)
	prefix := "-- name:"
	if !strings.has_prefix(trimmed, prefix) {
		return "", .Exec, false
	}

	rest := strings.trim_space(trimmed[len(prefix):])
	if len(rest) == 0 {
		return "", .Exec, false
	}

	// Split into name and command
	parts := strings.fields(rest)
	if len(parts) < 2 {
		return "", .Exec, false
	}

	name := parts[0]
	cmd_str := parts[1]

	// Validate name is a valid identifier
	if !is_valid_ident(name) {
		return "", .Exec, false
	}

	// Parse command
	cmd: Command
	ok: bool
	cmd, ok = parse_command(cmd_str)
	if !ok {
		return "", .Exec, false
	}

	return name, cmd, true
}

// Parse all queries from a SQL file. Returns metadata for each annotated query.
// Splits the file by annotations, returning the metadata and the SQL text for each query.
parse_queries :: proc(
	sql: string,
	filename: string,
	allocator := context.allocator,
) -> [dynamic]Query_Entry {
	entries := make([dynamic]Query_Entry, 0, 8, allocator)

	lines := strings.split(sql, "\n", allocator = context.temp_allocator)
	current_comments := make([dynamic]string, 0, 4, context.temp_allocator)
	current_meta: ^Metadata = nil
	sql_buf := strings.builder_make(context.temp_allocator)

	for line in lines {
		trimmed := strings.trim_space(line)

		// Try to parse as annotation
		name, cmd, is_annotation := parse_name_and_cmd(trimmed)
		if is_annotation {
			// Flush previous query if any
			if current_meta != nil {
				query_sql := strings.trim_space(strings.to_string(sql_buf))
				if len(query_sql) > 0 {
					append(&entries, Query_Entry{
						meta = Metadata{
							name     = strings.clone(current_meta.name, allocator),
							cmd      = current_meta.cmd,
							comments = clone_string_list(current_meta.comments, allocator),
							filename = strings.clone(filename, allocator),
						},
						sql = strings.clone(query_sql, allocator),
					})
				}
			}

			// Start new query
			m := new(Metadata, context.temp_allocator)
			m.name = name
			m.cmd = cmd
			m.comments = make([dynamic]string, 0, len(current_comments) + 4, context.temp_allocator)
			m.filename = filename
			// Copy accumulated comments
			for c in current_comments {
				append(&m.comments, c)
			}
			current_meta = m
			clear(&current_comments)
			strings.builder_reset(&sql_buf)
			continue
		}

		// Accumulate comments for the next annotation
		if strings.has_prefix(trimmed, "--") {
			if current_meta == nil {
				// Comment before any annotation — could be a doc comment
				comment_text := strings.trim_space(trimmed[2:])
				append(&current_comments, comment_text)
			} else {
				// Comment after annotation, before SQL — doc comment for the query
				comment_text := strings.trim_space(trimmed[2:])
				append(&current_meta.comments, comment_text)
			}
			continue
		}

		// Regular SQL line
		if current_meta != nil {
			if strings.builder_len(sql_buf) > 0 {
				strings.write_byte(&sql_buf, '\n')
			}
			strings.write_string(&sql_buf, line)
		} else {
			// Clear pending comments if we hit non-comment, non-annotation text
			// without an active query (e.g., stray SQL outside of annotations)
			clear(&current_comments)
		}
	}

	// Flush last query
	if current_meta != nil {
		query_sql := strings.trim_space(strings.to_string(sql_buf))
		if len(query_sql) > 0 {
			append(&entries, Query_Entry{
				meta = Metadata{
					name     = strings.clone(current_meta.name, allocator),
					cmd      = current_meta.cmd,
					comments = clone_string_list(current_meta.comments, allocator),
					filename = strings.clone(filename, allocator),
				},
				sql = strings.clone(query_sql, allocator),
			})
		}
	}

	return entries
}

Query_Entry :: struct {
	meta: Metadata,
	sql:  string, // the SQL text for this query (without the annotation comment)
}

// ── Helpers ───────────────────────────────────────────────────

parse_command :: proc(s: string) -> (Command, bool) {
	switch s {
	case ":one":        return .One, true
	case ":many":       return .Many, true
	case ":exec":       return .Exec, true
	case ":execresult": return .Exec_Result, true
	case ":execrows":   return .Exec_Rows, true
	}
	return .Exec, false
}

is_valid_ident :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	first := s[0]
	if !((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') || first == '_') {
		return false
	}
	for ch in s[1:] {
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
		     (ch >= '0' && ch <= '9') || ch == '_') {
			return false
		}
	}
	return true
}

clone_string_list :: proc(src: [dynamic]string, allocator := context.allocator) -> [dynamic]string {
	dst := make([dynamic]string, 0, len(src), allocator)
	for s in src {
		append(&dst, strings.clone(s, allocator))
	}
	return dst
}
