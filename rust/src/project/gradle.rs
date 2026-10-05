use super::common::push_command;
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(root: ProjectRoot, kind: ProjectKind) -> Result<Project, ProjectError> {
    let contents = read_marker(&root)?;
    let source = strip_gradle_comments(&contents);
    let executable = if root.root.join("gradlew").is_file() {
        "./gradlew"
    } else if root.root.join("gradlew.bat").is_file() {
        "gradlew.bat"
    } else {
        "gradle"
    };
    let mut project = Project::new(root, kind);
    for task in ["build", "test", "clean"] {
        push_command(&mut project.commands, task, &format!("{executable} {task}"));
    }
    if source.contains("org.springframework.boot") {
        push_command(
            &mut project.commands,
            "bootRun",
            &format!("{executable} bootRun"),
        );
    }
    if source.contains("id(\"application\")")
        || source.contains("id 'application'")
        || source.contains("application {")
    {
        push_command(&mut project.commands, "run", &format!("{executable} run"));
    }
    for task in declared_tasks(&source) {
        push_command(
            &mut project.commands,
            &task,
            &format!("{executable} {task}"),
        );
    }
    Ok(project)
}

fn strip_gradle_comments(contents: &str) -> String {
    let without_line_comments = strip_slash_comments(contents);
    strip_block_comments(&without_line_comments)
}

fn strip_slash_comments(contents: &str) -> String {
    let mut output = String::with_capacity(contents.len());
    let mut quote = None;
    let mut index = 0usize;
    while index < contents.len() {
        let byte = contents.as_bytes()[index];
        if let Some(active) = quote {
            output.push(byte as char);
            if byte == active {
                quote = None;
            } else if byte == b'\\' && index + 1 < contents.len() {
                index += 1;
                output.push(contents.as_bytes()[index] as char);
            }
            index += 1;
            continue;
        }
        if byte == b'"' || byte == b'\'' {
            quote = Some(byte);
            output.push(byte as char);
            index += 1;
        } else if byte == b'/' && contents.as_bytes().get(index + 1) == Some(&b'/') {
            output.push(' ');
            index += 2;
            while index < contents.len() && contents.as_bytes()[index] != b'\n' {
                output.push(' ');
                index += 1;
            }
        } else {
            output.push(byte as char);
            index += 1;
        }
    }
    output
}

fn strip_block_comments(contents: &str) -> String {
    let mut output = String::with_capacity(contents.len());
    let mut index = 0usize;
    while index < contents.len() {
        if contents.as_bytes().get(index..index + 2) == Some(b"/*") {
            output.push(' ');
            output.push(' ');
            index += 2;
            while index + 1 < contents.len() && &contents.as_bytes()[index..index + 2] != b"*/" {
                output.push(if contents.as_bytes()[index] == b'\n' {
                    '\n'
                } else {
                    ' '
                });
                index += 1;
            }
            if index + 1 < contents.len() {
                output.push(' ');
                output.push(' ');
                index += 2;
            }
        } else {
            output.push(contents.as_bytes()[index] as char);
            index += 1;
        }
    }
    output
}

fn declared_tasks(source: &str) -> Vec<String> {
    let mut tasks = Vec::new();
    for prefix in ["tasks.register", "tasks.create", "tasks.named", "task("] {
        let mut offset = 0;
        while let Some(relative) = source[offset..].find(prefix) {
            let start = offset + relative + prefix.len();
            let rest = &source[start..];
            let Some(quote_index) = rest.find(['\'', '"']) else {
                break;
            };
            let quote = rest.as_bytes()[quote_index];
            let rest = &rest[quote_index + 1..];
            let Some(end) = rest.find(quote as char) else {
                break;
            };
            let name = &rest[..end];
            if super::common::valid_name(name) && !tasks.iter().any(|task| task == name) {
                tasks.push(name.to_owned());
            }
            offset = start + quote_index + end + 2;
        }
    }
    tasks
}
