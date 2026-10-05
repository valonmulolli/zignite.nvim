pub fn strip_ansi(line: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(line.len());
    let mut index = 0;
    while index < line.len() {
        if line[index] == 0x1b && index + 1 < line.len() {
            match line[index + 1] {
                b'[' => {
                    index += 2;
                    while index < line.len() {
                        let byte = line[index];
                        index += 1;
                        if (0x40..=0x7e).contains(&byte) {
                            break;
                        }
                    }
                    continue;
                }
                b']' | b'P' | b'X' | b'^' | b'_' => {
                    index += 2;
                    while index < line.len() {
                        if line[index] == 0x07 {
                            index += 1;
                            break;
                        }
                        if line[index] == 0x1b && index + 1 < line.len() && line[index + 1] == b'\\'
                        {
                            index += 2;
                            break;
                        }
                        index += 1;
                    }
                    continue;
                }
                _ => {}
            }
        }
        output.push(line[index]);
        index += 1;
    }
    output
}
