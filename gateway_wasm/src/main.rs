use std::io::{self, Read, Write};

fn main() {
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input).unwrap();

    // deterministic transform
    let mut output = b"wasm:".to_vec();
    output.extend_from_slice(&input);

    io::stdout().write_all(&output).unwrap();
}
