@tool
class_name WMTFileLoader
extends ResourceFormatLoader
# Lets Godot recognize .wmt chunk files as resources so they appear in the
# editor FileSystem dock and file dialogs (a plain .wmt is otherwise invisible
# to the editor because nothing declares the extension). GDScript loaders with
# a global class_name are auto-registered with ResourceLoader, so no explicit
# registration call is needed.
#
# The terrain data is read/written by WMT itself (save_wmt/load_wmt); this
# loader only advertises the type so the editor indexes and displays the files.
# Loading a .wmt through ResourceLoader yields a plain Resource carrying the
# path, which is enough for drag-and-drop / inspector contexts.

func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["wmt"])

func _recognize(path: String) -> bool:
	return path.get_extension().to_lower() == "wmt"

func _handles_type(a_type: StringName) -> bool:
	return a_type == "WMTFile"

func _get_resource_type(path: String) -> String:
	if path.get_extension().to_lower() == "wmt":
		return "WMTFile"
	return ""

func _load(_path: String, _original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Resource:
	var r := Resource.new()
	r.resource_path = _path
	return r

func _exists(path: String) -> bool:
	return path.get_extension().to_lower() == "wmt" and FileAccess.file_exists(path)