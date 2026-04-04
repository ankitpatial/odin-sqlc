package codegen

import "core:strings"
import "core:unicode/utf8"

// Convert "foo_bar" or "fooBar" to "FooBar" (PascalCase).
to_pascal_case :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 {return ""}
	buf := strings.builder_make(allocator)
	capitalize_next := true
	for ch in s {
		if ch == '_' || ch == ' ' || ch == '-' {
			capitalize_next = true
			continue
		}

		if capitalize_next {
			if ch >= 'a' && ch <= 'z' {
				strings.write_rune(&buf, ch - 'a' + 'A')
			} else {
				strings.write_rune(&buf, ch)
			}
			capitalize_next = false
		} else {
			strings.write_rune(&buf, ch)
		}
	}
	return strings.to_string(buf)
}

// Convert "foo_bar" to "Foo_Bar" (PascalCase with underscores preserved).
to_pascal_snake :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 {return ""}
	buf := strings.builder_make(allocator)
	capitalize_next := true
	for ch in s {
		if ch == '_' || ch == ' ' || ch == '-' {
			strings.write_byte(&buf, '_')
			capitalize_next = true
			continue
		}
		if capitalize_next {
			if ch >= 'a' && ch <= 'z' {
				strings.write_rune(&buf, ch - 'a' + 'A')
			} else {
				strings.write_rune(&buf, ch)
			}
			capitalize_next = false
		} else {
			strings.write_rune(&buf, ch)
		}
	}
	return strings.to_string(buf)
}

// Convert "foo_bar" to "foo_bar" (Odin proc convention — already snake_case).
to_snake_case :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) == 0 {return ""}
	buf := strings.builder_make(allocator)

	prev_was_upper := false
	for ch, i in s {
		is_upper := ch >= 'A' && ch <= 'Z'
		if is_upper && i > 0 && !prev_was_upper {
			strings.write_byte(&buf, '_')
		}
		if is_upper {
			strings.write_rune(&buf, ch - 'A' + 'a')
		} else {
			strings.write_rune(&buf, ch)
		}
		prev_was_upper = is_upper
	}
	return strings.to_string(buf)
}

// Singularize a table name for struct names.
// Simple heuristic: remove trailing 's' if present.
singularize :: proc(s: string) -> string {
	if len(s) <= 1 {return s}
	if strings.has_suffix(s, "ies") {
		return strings.concatenate({s[:len(s) - 3], "y"})
	}
	if strings.has_suffix(s, "ses") ||
	   strings.has_suffix(s, "xes") ||
	   strings.has_suffix(s, "zes") ||
	   strings.has_suffix(s, "ches") ||
	   strings.has_suffix(s, "shes") {
		return s[:len(s) - 2]
	}
	if strings.has_suffix(s, "s") && !strings.has_suffix(s, "ss") {
		return s[:len(s) - 1]
	}
	return s
}

// Convert a table name to an Odin struct name.
// "users" → "User", "order_items" → "Order_Item"
table_to_struct :: proc(name: string, allocator := context.allocator) -> string {
	singular := singularize(name)
	return to_pascal_case(singular, allocator)
}

// Convert an enum value to an Odin enum variant.
// "op!en" → "Op_En", "closed" → "Closed", "clo@sed" → "Clo_Sed"
// Strips non-alphanumeric characters, inserting underscore at breaks.
enum_val_to_variant :: proc(val: string, allocator := context.allocator) -> string {
	buf := strings.builder_make(allocator)
	capitalize_next := true
	had_content := false
	for ch in val {
		if !((ch >= 'a' && ch <= 'z') ||
			   (ch >= 'A' && ch <= 'Z') ||
			   (ch >= '0' && ch <= '9') ||
			   ch == '_') {
			// Non-alnum character — insert separator for next segment
			if had_content {
				capitalize_next = true
			}
			continue
		}
		if capitalize_next && had_content && ch != '_' {
			strings.write_byte(&buf, '_')
		}
		if capitalize_next {
			if ch >= 'a' && ch <= 'z' {
				strings.write_rune(&buf, ch - 'a' + 'A')
			} else {
				strings.write_rune(&buf, ch)
			}
			capitalize_next = false
		} else {
			strings.write_rune(&buf, ch)
		}
		had_content = true
	}
	return strings.to_string(buf)
}
