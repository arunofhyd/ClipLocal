import sys

with open("/Users/thomasarun/ClipLocal/main.swift", "r") as f:
    content = f.read()

content = content.replace(
    '    @State private var dragStartHeight: Double? = nil',
    '    @State private var dragStartHeight: Double? = nil\n    @Environment(\\.colorScheme) var colorScheme'
)

content = content.replace(
    '            .listStyle(.plain)\n            .background(Color.clear)',
    '            .listStyle(.plain)\n            .background(Color.clear)\n            .scrollContentBackground(colorScheme == .light ? .hidden : .visible)'
)

with open("/Users/thomasarun/ClipLocal/main.swift", "w") as f:
    f.write(content)

