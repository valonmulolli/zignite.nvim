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
    let mut output = String::with_capacity(contents.len());
    let mut quote = None;
    let mut line_comment = false;
    let mut block_comment = false;
    let mut index = 0usize;
    let characters = contents.chars().collect::<Vec<_>>();
    while index < characters.len() {
        let character = characters[index];
        let next = characters.get(index + 1).copied();
        if line_comment {
            if character == '\n' {
                output.push('\n');
                line_comment = false;
            } else {
                output.push(' ');
            }
            index += 1;
            continue;
        }
        if block_comment {
            if character == '*' && next == Some('/') {
                output.push_str("  ");
                block_comment = false;
                index += 2;
            } else {
                output.push(if character == '\n' { '\n' } else { ' ' });
                index += 1;
            }
            continue;
        }
        if let Some(active) = quote {
            output.push(character);
            if character == '\\' && index + 1 < characters.len() {
                index += 1;
                output.push(characters[index]);
            } else if character == active {
                quote = None;
            }
            index += 1;
            continue;
        }
        if character == '\'' || character == '"' {
            quote = Some(character);
            output.push(character);
            index += 1;
        } else if character == '/' && next == Some('/') {
            output.push_str("  ");
            line_comment = true;
            index += 2;
        } else if character == '/' && next == Some('*') {
            output.push_str("  ");
            block_comment = true;
            index += 2;
        } else {
            output.push(character);
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
