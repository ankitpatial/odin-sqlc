package pq

import "core:strconv"
import "core:strings"

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
	src := raw[:length]
	return strings.clone_from_bytes(src, allocator), true
}

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

get_i32 :: proc(res: Result, row: i32, col: i32) -> (i32, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string(raw[:length])
	val, ok := strconv.parse_int(text)
	if !ok {
		return 0, false
	}
	return i32(val), true
}

get_maybe_i32 :: proc(res: Result, row: i32, col: i32) -> Maybe(i32) {
	val, ok := get_i32(res, row, col)
	if !ok {
		return nil
	}
	return val
}

get_i64 :: proc(res: Result, row: i32, col: i32) -> (i64, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string(raw[:length])
	val, ok := strconv.parse_int(text)
	if !ok {
		return 0, false
	}
	return i64(val), true
}

get_maybe_i64 :: proc(res: Result, row: i32, col: i32) -> Maybe(i64) {
	val, ok := get_i64(res, row, col)
	if !ok {
		return nil
	}
	return val
}

get_i16 :: proc(res: Result, row: i32, col: i32) -> (i16, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string(raw[:length])
	val, ok := strconv.parse_int(text)
	if !ok {
		return 0, false
	}
	return i16(val), true
}

get_maybe_i16 :: proc(res: Result, row: i32, col: i32) -> Maybe(i16) {
	val, ok := get_i16(res, row, col)
	if !ok {
		return nil
	}
	return val
}

get_f64 :: proc(res: Result, row: i32, col: i32) -> (f64, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string(raw[:length])
	val, ok := strconv.parse_f64(text)
	if !ok {
		return 0, false
	}
	return val, true
}

get_maybe_f64 :: proc(res: Result, row: i32, col: i32) -> Maybe(f64) {
	val, ok := get_f64(res, row, col)
	if !ok {
		return nil
	}
	return val
}

get_f32 :: proc(res: Result, row: i32, col: i32) -> (f32, bool) {
	if get_is_null(res, row, col) {
		return 0, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return 0, false
	}
	text := string(raw[:length])
	val, ok := strconv.parse_f64(text)
	if !ok {
		return 0, false
	}
	return f32(val), true
}

get_maybe_f32 :: proc(res: Result, row: i32, col: i32) -> Maybe(f32) {
	val, ok := get_f32(res, row, col)
	if !ok {
		return nil
	}
	return val
}

get_bool :: proc(res: Result, row: i32, col: i32) -> (bool, bool) {
	if get_is_null(res, row, col) {
		return false, false
	}
	raw := get_value(res, row, col)
	length := get_length(res, row, col)
	if length == 0 {
		return false, false
	}
	first_byte := raw[0]
	return first_byte == 't' || first_byte == 'T', true
}

get_maybe_bool :: proc(res: Result, row: i32, col: i32) -> Maybe(bool) {
	val, ok := get_bool(res, row, col)
	if !ok {
		return nil
	}
	return val
}

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
	src := raw[:length]
	dst := make([]byte, length, allocator)
	copy(dst, src)
	return dst, true
}

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
