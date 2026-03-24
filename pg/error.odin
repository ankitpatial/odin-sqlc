package pq

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

result_error :: proc(res: Result) -> cstring {
	if res == nil {
		return "out of memory"
	}
	return result_error_message(res)
}
