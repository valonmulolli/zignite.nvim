use serde::ser::{SerializeStruct, Serializer};
use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BuildSource {
    Config,
    Project,
    Builtin,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CommandEntry {
    pub name: String,
    pub command: String,
    pub display_command: String,
    pub requires_arguments: bool,
    pub argument_prompt: Option<String>,
    pub argument_help: Option<String>,
    pub source: BuildSource,
}

impl CommandEntry {
    pub fn new(name: impl Into<String>, command: impl Into<String>, source: BuildSource) -> Self {
        let command = command.into();
        let requires_arguments = command.contains("$zignite_args");
        let display_command = command.replace("$zignite_args", "<args>");
        let name = name.into();
        let argument_prompt = requires_arguments.then(|| argument_prompt("", &name));
        let argument_help = requires_arguments.then(|| argument_help("", &name));
        Self {
            name,
            command,
            display_command,
            requires_arguments,
            argument_prompt,
            argument_help,
            source,
        }
    }

    pub fn with_filetype(mut self, filetype: &str) -> Self {
        if self.requires_arguments {
            self.argument_prompt = Some(argument_prompt(filetype, &self.name));
            self.argument_help = Some(argument_help(filetype, &self.name));
        }
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedBuild {
    pub ok: bool,
    pub reason: Option<String>,
    pub message: Option<String>,
    pub filetype: String,
    pub root: Option<String>,
    pub system: Option<String>,
    pub build_ready: Option<bool>,
    pub commands: Vec<CommandEntry>,
    pub command_entries: Vec<CommandEntry>,
    pub completion_names: Vec<String>,
    pub preferred_commands: Vec<CommandEntry>,
    pub preferred_names: Vec<String>,
    pub live_preferred_name: Option<String>,
    pub last_command_name: Option<String>,
    pub config_revision: u64,
}

impl ResolvedBuild {
    pub fn command(&self, name: &str) -> Option<&CommandEntry> {
        self.commands.iter().find(|entry| entry.name == name)
    }
}

impl Serialize for ResolvedBuild {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let commands = self
            .commands
            .iter()
            .map(|entry| (entry.name.clone(), entry.command.clone()))
            .collect::<BTreeMap<_, _>>();
        let preferred_commands = self
            .preferred_commands
            .iter()
            .map(|entry| (entry.name.clone(), entry.command.clone()))
            .collect::<BTreeMap<_, _>>();
        let preferred_names = self
            .live_preferred_name
            .as_ref()
            .map(|name| BTreeMap::from([(String::from("live"), name.clone())]));
        let command_meta = self
            .commands
            .iter()
            .map(|entry| {
                (
                    entry.name.clone(),
                    CommandMeta {
                        display_command: entry.display_command.clone(),
                        requires_arguments: entry.requires_arguments,
                        argument_prompt: entry.argument_prompt.clone(),
                        argument_help: entry.argument_help.clone(),
                        picker_section: picker_section(&entry.name),
                        picker_rank: picker_rank(&entry.name),
                        hide_in_picker: false,
                    },
                )
            })
            .collect::<BTreeMap<_, _>>();
        let mut command_entries = self.commands.clone();
        command_entries.sort_by(|left, right| {
            let left_last = self.last_command_name.as_deref() == Some(left.name.as_str());
            let right_last = self.last_command_name.as_deref() == Some(right.name.as_str());
            right_last
                .cmp(&left_last)
                .then_with(|| picker_rank(&left.name).cmp(&picker_rank(&right.name)))
                .then_with(|| left.name.cmp(&right.name))
        });
        let command_entries = command_entries
            .into_iter()
            .map(|entry| {
                let picker_section = picker_section_from_name(&entry.name);
                let picker_rank = picker_rank(&entry.name);
                PickerCommand {
                    name: entry.name,
                    command: entry.command,
                    display_command: entry.display_command,
                    requires_arguments: entry.requires_arguments,
                    argument_prompt: entry.argument_prompt,
                    argument_help: entry.argument_help,
                    picker_section,
                    picker_rank,
                }
            })
            .collect::<Vec<_>>();
        let completion_names = command_entries
            .iter()
            .map(|entry| entry.name.clone())
            .collect::<Vec<_>>();

        let mut output = serializer.serialize_struct("ResolvedBuild", 16)?;
        output.serialize_field("ok", &self.ok)?;
        if let Some(reason) = &self.reason {
            output.serialize_field("reason", reason)?;
        }
        if let Some(message) = &self.message {
            output.serialize_field("message", message)?;
        }
        if let Some(root) = &self.root {
            output.serialize_field("root", root)?;
        }
        output.serialize_field("filetype", &self.filetype)?;
        if let Some(system) = &self.system {
            output.serialize_field("system", system)?;
        }
        if let Some(build_ready) = self.build_ready {
            output.serialize_field("build_ready", &build_ready)?;
        }
        output.serialize_field("config_revision", &self.config_revision)?;
        output.serialize_field("commands", &commands)?;
        output.serialize_field("command_meta", &command_meta)?;
        output.serialize_field("command_entries", &command_entries)?;
        output.serialize_field("completion_names", &completion_names)?;
        output.serialize_field("preferred_commands", &preferred_commands)?;
        output.serialize_field("preferred_names", &preferred_names.unwrap_or_default())?;
        if let Some(last) = &self.last_command_name {
            output.serialize_field("last_command_name", last)?;
        }
        output.end()
    }
}

#[derive(Serialize)]
struct CommandMeta {
    display_command: String,
    requires_arguments: bool,
    argument_prompt: Option<String>,
    argument_help: Option<String>,
    picker_section: &'static str,
    picker_rank: usize,
    hide_in_picker: bool,
}

#[derive(Serialize)]
struct PickerCommand {
    name: String,
    command: String,
    display_command: String,
    requires_arguments: bool,
    argument_prompt: Option<String>,
    argument_help: Option<String>,
    picker_section: &'static str,
    picker_rank: usize,
}

fn picker_section(name: &str) -> &'static str {
    let semantic_name = name.split_once('-').map_or(name, |(_, rest)| rest);
    if matches!(
        semantic_name,
        "build"
            | "run"
            | "clean"
            | "test"
            | "install"
            | "check"
            | "dev"
            | "start"
            | "watch"
            | "serve"
            | "preview"
            | "mod"
            | "fetch"
    ) {
        "common"
    } else if matches!(semantic_name, "config" | "setup" | "debug" | "release") {
        "profiles"
    } else if name.contains("build-") || name.contains("run-") {
        "targets"
    } else {
        "other"
    }
}

fn picker_section_from_name(name: &str) -> &'static str {
    picker_section(name)
}

fn picker_rank(name: &str) -> usize {
    let section_rank = match picker_section(name) {
        "common" => 1,
        "targets" => 2,
        "profiles" => 3,
        _ => 4,
    };
    let semantic_name = name.split_once('-').map_or(name, |(_, rest)| rest);
    let name_rank = match semantic_name {
        "build" => 1,
        "run" => 2,
        "clean" => 3,
        "test" => 4,
        "install" => 5,
        "check" => 6,
        "dev" => 7,
        "start" => 8,
        "watch" => 9,
        "serve" => 10,
        "preview" => 11,
        "mod" => 12,
        "fetch" => 13,
        "config" => 1,
        "setup" => 2,
        "debug" => 3,
        "release" => 4,
        _ => 999,
    };
    section_rank * 1000 + name_rank
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActionKind {
    Named,
    Live,
    Last,
}

#[derive(Debug, Default)]
pub struct BuildState {
    last_commands: std::collections::HashMap<String, String>,
    tool_cache: super::cache::CommandCache,
}

impl BuildState {
    pub(crate) fn last(&self, filetype: &str) -> Option<&str> {
        self.last_commands.get(filetype).map(String::as_str)
    }

    pub(crate) fn remember(&mut self, filetype: &str, command: &str) {
        self.last_commands
            .insert(filetype.to_owned(), command.to_owned());
    }

    pub(crate) fn clear(&mut self, filetype: &str) {
        self.last_commands.remove(filetype);
    }

    pub(crate) fn tool_available(&mut self, tool: &str, cwd: &str) -> bool {
        self.tool_cache.available(tool, cwd)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ActionPlan {
    pub ok: bool,
    pub reason: Option<String>,
    pub message: Option<String>,
    pub resolved_command_name: Option<String>,
    pub requires_arguments: bool,
    pub argument_prompt: Option<String>,
    pub argument_help: Option<String>,
    pub filetype: Option<String>,
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub missing_tool: Option<String>,
    pub exec_command: Option<String>,
    pub exec_argv: Vec<String>,
    pub system_argv: Vec<String>,
    pub config_revision: u64,
}

pub(crate) fn argument_prompt(filetype: &str, command: &str) -> String {
    if filetype == "zig" && command == "fetch" {
        "zig fetch url/path".to_owned()
    } else if filetype.is_empty() {
        format!("{command} args")
    } else {
        format!("{filetype} {command} args")
    }
}

pub(crate) fn argument_help(filetype: &str, command: &str) -> String {
    if filetype == "zig" && command == "fetch" {
        "Paste GitHub URL only | Enter: run | Esc: cancel | Backspace: edit".to_owned()
    } else {
        "Type arguments | Enter: run | Esc: cancel | Backspace: edit".to_owned()
    }
}
