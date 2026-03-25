package cli

import "core:fmt"

SQLD_VERSION :: "0.1.0-dev"

cmd_version :: proc() {
	fmt.printf("sqld v%s\n", SQLD_VERSION)
}
