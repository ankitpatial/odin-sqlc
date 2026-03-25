package source

import "core:strings"
import "core:slice"

// An edit to the source text (position + replacement)
Edit :: struct {
	location: i32,  // byte offset in original source
	old_len:  i32,  // bytes to replace
	new_text: string, // replacement text
}

// Extract the SQL text for a specific statement from a multi-statement file.
// If length is 0, returns from location to end of source.
pluck :: proc(src: string, location: i32, length: i32) -> string {
	loc := int(location)
	if loc >= len(src) {
		return ""
	}
	if length == 0 {
		return src[loc:]
	}
	end := loc + int(length)
	if end > len(src) {
		end = len(src)
	}
	return src[loc:end]
}

// Apply accumulated edits to source text.
// Edits are applied in reverse order of location to preserve offsets.
mutate :: proc(src: string, edits: []Edit, allocator := context.allocator) -> string {
	if len(edits) == 0 {
		return strings.clone(src, allocator)
	}

	// Sort edits by location descending (apply from end to start)
	sorted := make([]Edit, len(edits), context.temp_allocator)
	copy(sorted, edits)
	slice.sort_by(sorted, proc(a, b: Edit) -> bool {
		return a.location > b.location
	})

	result := strings.clone(src, context.temp_allocator)
	for edit in sorted {
		loc := int(edit.location)
		end := loc + int(edit.old_len)
		if loc > len(result) { continue }
		if end > len(result) { end = len(result) }

		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, result[:loc])
		strings.write_string(&b, edit.new_text)
		strings.write_string(&b, result[end:])
		result = strings.to_string(b)
	}

	return strings.clone(result, allocator)
}

// Remove SQL comments from query text.
// Handles -- line comments and /* block comments */.
strip_comments :: proc(src: string, allocator := context.allocator) -> string {
	buf := strings.builder_make(allocator)
	i := 0
	for i < len(src) {
		// Line comment
		if i + 1 < len(src) && src[i] == '-' && src[i + 1] == '-' {
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			continue
		}
		// Block comment
		if i + 1 < len(src) && src[i] == '/' && src[i + 1] == '*' {
			i += 2
			for i + 1 < len(src) {
				if src[i] == '*' && src[i + 1] == '/' {
					i += 2
					break
				}
				i += 1
			}
			continue
		}
		strings.write_byte(&buf, src[i])
		i += 1
	}
	return strings.to_string(buf)
}

// Get line number from byte offset (1-based).
line_number :: proc(src: string, offset: i32) -> i32 {
	off := int(offset)
	if off > len(src) {
		off = len(src)
	}
	line: i32 = 1
	for i := 0; i < off; i += 1 {
		if src[i] == '\n' {
			line += 1
		}
	}
	return line
}
