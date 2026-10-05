use super::common::push_command;
use super::core::{read_marker, Project, ProjectError, ProjectKind, ProjectRoot};

pub(super) fn parse(root: ProjectRoot, kind: ProjectKind) -> Result<Project, ProjectError> {
    let contents = read_marker(&root)?;
    if !contents.contains("<project") || !contents.contains("</project>") {
        return Err(super::common::invalid_file(
            &root.marker,
            "missing project XML element",
        ));
    }
    let mut project = Project::new(root, kind);
    push_command(&mut project.commands, "build", "mvn compile");
    push_command(&mut project.commands, "test", "mvn test");
    push_command(&mut project.commands, "clean", "mvn clean");
    if contents.contains("spring-boot-maven-plugin") {
        push_command(&mut project.commands, "run", "mvn spring-boot:run");
    }
    Ok(project)
}
