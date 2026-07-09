import sys
with open("index.html", "r") as f:
    content = f.read()

# Let's replace any static text 1.6 that might be lingering.
# Oh, it is in the SVG path data for the apple logo lol! `1.156-1.688 1.636-3.325` -> `1.636` contains 1.6!
