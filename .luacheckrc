std = "lua51"
globals = {
	"vim",
}

max_line_length = 120

files["example_config.lua"] = {
	max_line_length = false,
}

files["lazy_config.lua"] = {
	max_line_length = false,
}

files["lua/zignite/config.lua"] = {
	max_line_length = false,
}

files["lua/zignite/utils.lua"] = {
	max_line_length = false,
}

files["test/*.lua"] = {
	max_line_length = false,
}
