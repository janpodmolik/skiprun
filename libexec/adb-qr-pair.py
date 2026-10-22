#!/usr/bin/env python3
"""Render the ADB wireless-debugging pairing QR in the terminal.

Android's "Pair device with QR code" scans a plain string:
    WIFI:T:ADB;S:<service-name>;P:<password>;;
The phone then advertises an mDNS pairing service named <service-name> and
pairs using <password> as the code. Android Studio is normally the thing that
shows this QR; this script replaces it so `adb` alone is enough.

Self-contained byte-mode QR encoder (versions 1-10, ECC level L) — no deps.
"""

import sys

# --- Galois field arithmetic over GF(256) for Reed-Solomon ---
EXP = [0] * 512
LOG = [0] * 256
_x = 1
for _i in range(255):
    EXP[_i] = _x
    LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    EXP[_i] = EXP[_i - 255]


def gf_mul(a, b):
    if a == 0 or b == 0:
        return 0
    return EXP[LOG[a] + LOG[b]]


def rs_generator(degree):
    poly = [1]
    for i in range(degree):
        new = [0] * (len(poly) + 1)
        for j, coef in enumerate(poly):
            new[j] ^= coef
            new[j + 1] ^= gf_mul(coef, EXP[i])
        poly = new
    return poly


def rs_encode(data, ec_len):
    gen = rs_generator(ec_len)
    remainder = [0] * ec_len
    for byte in data:
        factor = byte ^ remainder[0]
        remainder = remainder[1:] + [0]
        for i, coef in enumerate(gen[1:]):
            remainder[i] ^= gf_mul(coef, factor)
    return remainder


# Per-version (1-10) ECC-L parameters: (total codewords, ec codewords per block, block count)
VERSION_INFO = {
    1: (26, 7, 1),
    2: (44, 10, 1),
    3: (70, 15, 1),
    4: (100, 20, 1),
    5: (134, 26, 1),
    6: (172, 18, 2),
    7: (196, 20, 2),
    8: (242, 24, 2),
    9: (292, 30, 2),
    10: (346, 18, 4),
}

ALIGNMENT_POSITIONS = {
    1: [],
    2: [6, 18],
    3: [6, 22],
    4: [6, 26],
    5: [6, 30],
    6: [6, 34],
    7: [6, 22, 38],
    8: [6, 24, 42],
    9: [6, 26, 46],
    10: [6, 28, 50],
}

# Pre-computed BCH format strings for ECC level L, masks 0-7.
FORMAT_BITS_L = [
    0x77C4, 0x72F3, 0x7DAA, 0x789D,
    0x662F, 0x6318, 0x6C41, 0x6976,
]


def pick_version(data_len):
    # Capped at 6: version 7+ additionally carries version-information blocks,
    # which this encoder doesn't emit. An ADB pairing payload is ~40 bytes.
    for version in range(1, 7):
        total, ec_per_block, blocks = VERSION_INFO[version]
        capacity = total - ec_per_block * blocks
        needed = (4 + 8 + data_len * 8 + 7) // 8  # byte mode: 4 mode bits + 8 count bits
        if needed <= capacity:
            return version
    raise ValueError("payload too long for this encoder (max version 6)")


def build_codewords(text, version):
    data = text.encode("utf-8")
    total, ec_per_block, blocks = VERSION_INFO[version]
    capacity = total - ec_per_block * blocks
    count_bits = 8 if version < 10 else 16

    bits = []
    for bit in range(3, -1, -1):
        bits.append((0b0100 >> bit) & 1)  # byte mode
    for bit in range(count_bits - 1, -1, -1):
        bits.append((len(data) >> bit) & 1)
    for byte in data:
        for bit in range(7, -1, -1):
            bits.append((byte >> bit) & 1)

    bits.extend([0] * min(4, capacity * 8 - len(bits)))
    while len(bits) % 8:
        bits.append(0)

    codewords = [int("".join(str(b) for b in bits[i:i + 8]), 2) for i in range(0, len(bits), 8)]
    pad = [0xEC, 0x11]
    while len(codewords) < capacity:
        codewords.append(pad[(len(codewords) - len(bits) // 8) % 2])

    # Split into blocks, interleave data then ECC.
    per_block = capacity // blocks
    extra = capacity % blocks
    data_blocks, ec_blocks = [], []
    offset = 0
    for index in range(blocks):
        size = per_block + (1 if index >= blocks - extra else 0)
        block = codewords[offset:offset + size]
        offset += size
        data_blocks.append(block)
        ec_blocks.append(rs_encode(block, ec_per_block))

    result = []
    for i in range(max(len(b) for b in data_blocks)):
        for block in data_blocks:
            if i < len(block):
                result.append(block[i])
    for i in range(ec_per_block):
        for block in ec_blocks:
            result.append(block[i])
    return result


def make_matrix(version, codewords, mask):
    size = version * 4 + 17
    modules = [[None] * size for _ in range(size)]

    def place_finder(row, col):
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                r, c = row + dr, col + dc
                if 0 <= r < size and 0 <= c < size:
                    inner = 0 <= dr <= 6 and 0 <= dc <= 6
                    dark = inner and (dr in (0, 6) or dc in (0, 6) or (2 <= dr <= 4 and 2 <= dc <= 4))
                    modules[r][c] = dark

    place_finder(0, 0)
    place_finder(0, size - 7)
    place_finder(size - 7, 0)

    for i in range(8, size - 8):
        modules[6][i] = i % 2 == 0
        modules[i][6] = i % 2 == 0

    positions = ALIGNMENT_POSITIONS[version]
    for row in positions:
        for col in positions:
            if (row < 8 and col < 8) or (row < 8 and col > size - 9) or (row > size - 9 and col < 8):
                continue
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    modules[row + dr][col + dc] = max(abs(dr), abs(dc)) != 1

    modules[size - 8][8] = False  # dark module — reserved here, set after format bits

    # Reserve format areas so data placement skips them.
    for i in range(9):
        if modules[8][i] is None:
            modules[8][i] = False
        if modules[i][8] is None:
            modules[i][8] = False
    for i in range(size - 8, size):
        if modules[8][i] is None:
            modules[8][i] = False
        if modules[i][8] is None:
            modules[i][8] = False

    reserved = [[modules[r][c] is not None for c in range(size)] for r in range(size)]

    def mask_fn(row, col):
        if mask == 0:
            return (row + col) % 2 == 0
        if mask == 1:
            return row % 2 == 0
        if mask == 2:
            return col % 3 == 0
        if mask == 3:
            return (row + col) % 3 == 0
        if mask == 4:
            return (row // 2 + col // 3) % 2 == 0
        if mask == 5:
            return (row * col) % 2 + (row * col) % 3 == 0
        if mask == 6:
            return ((row * col) % 2 + (row * col) % 3) % 2 == 0
        return ((row + col) % 2 + (row * col) % 3) % 2 == 0

    bit_stream = []
    for byte in codewords:
        for bit in range(7, -1, -1):
            bit_stream.append((byte >> bit) & 1)

    # Column pairs run right-to-left, snaking up then down. The vertical timing
    # column (6) is skipped entirely without disturbing the two-column stride.
    index = 0
    upward = True
    col = size - 1
    while col > 0:
        for row in (range(size - 1, -1, -1) if upward else range(size)):
            for c in (col, col - 1):
                if reserved[row][c]:
                    continue
                bit = bit_stream[index] if index < len(bit_stream) else 0
                index += 1
                modules[row][c] = bool(bit) != mask_fn(row, c)
        upward = not upward
        col -= 2
        if col == 6:
            col -= 1

    # Format bit i counts from the MOST significant bit of the 15-bit string.
    fmt = FORMAT_BITS_L[mask]
    for i in range(15):
        bit = (fmt >> (14 - i)) & 1
        if i < 6:
            modules[8][i] = bool(bit)
        elif i == 6:
            modules[8][7] = bool(bit)
        elif i == 7:
            modules[8][8] = bool(bit)
        elif i == 8:
            modules[7][8] = bool(bit)
        else:
            modules[14 - i][8] = bool(bit)
    for i in range(15):
        bit = (fmt >> (14 - i)) & 1
        if i < 8:
            modules[size - 1 - i][8] = bool(bit)
        else:
            modules[8][size - 15 + i] = bool(bit)

    # Always-dark modules that sit in the reserved format areas but carry no bit.
    modules[size - 8][8] = True
    modules[8][size - 8] = True

    return [[bool(cell) for cell in row] for row in modules]


def render(matrix):
    size = len(matrix)
    quiet = 2
    grid = [[False] * (size + quiet * 2) for _ in range(size + quiet * 2)]
    for r in range(size):
        for c in range(size):
            grid[r + quiet][c + quiet] = matrix[r][c]

    # Two vertical modules per character cell via half-block glyphs.
    lines = []
    for row in range(0, len(grid), 2):
        line = ""
        for col in range(len(grid[0])):
            top = grid[row][col]
            bottom = grid[row + 1][col] if row + 1 < len(grid) else False
            if top and bottom:
                line += "█"
            elif top:
                line += "▀"
            elif bottom:
                line += "▄"
            else:
                line += " "
        lines.append(line)
    return "\n".join(lines)


def main():
    if len(sys.argv) != 2:
        print("usage: adb-qr-pair.py <payload>", file=sys.stderr)
        return 2
    payload = sys.argv[1]
    version = pick_version(len(payload.encode("utf-8")))
    codewords = build_codewords(payload, version)
    print(render(make_matrix(version, codewords, 0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
