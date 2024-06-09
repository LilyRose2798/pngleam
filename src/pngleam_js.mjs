import { BitArray, toList } from "./gleam.mjs"

export const subUnfilter = (row, bpp) => {
    const state = Buffer.alloc(bpp)
    return new BitArray(new Uint8Array(row.buffer.map((x, i) => {
        const j = i % bpp
        const y = x + state[j]
        state[j] = y
        return y
    })))
}

export const upUnfilter = (row, above) => new BitArray(new Uint8Array(row.buffer.map((x, i) => x + above[i])))

const avg = (a, b) => Math.floor((a + b) / 2)

export const avgUnfilter = (row, above, bpp) => {
    const state = Buffer.alloc(bpp)
    return new BitArray(new Uint8Array(row.buffer.map((x, i) => {
        const j = i % bpp
        const y = x + avg(state[j], above[i])
        state[j] = y
        return y
    })))
}

const paeth = (a, b, c) => {
    const p = a + b - c // initial estimate
    const pa = Math.abs(p - a) // distances to a, b, c
    const pb = Math.abs(p - b)
    const pc = Math.abs(p - c)
    // return nearest of a,b,c,
    // breaking ties in order a,b,c.
    if (pa <= pb && pa <= pc) return a
    else if (pb <= pc) return b
    else return c
}

export const paethUnfilter = (row, above, bpp) => {
    const state = Buffer.alloc(bpp)
    return new BitArray(new Uint8Array(row.buffer.map((x, i) => {
        const j = i % bpp
        const y = x + paeth(state[j], above[i], above[i - bpp] ?? 0)
        state[j] = y
        return y
    })))
}

const doAddBytewise = (as, bs) => as.map((x, i) => x + bs[i])
export const addBytewise = (as, bs) => new BitArray(new Uint8Array(doAddBytewise(as.buffer, bs.buffer)))

const doSubBytewise = (as, bs) => as.map((a, i) => a - bs[i])
export const subBytewise = (as, bs) => new BitArray(new Uint8Array(doSubBytewise(as.buffer, bs.buffer)))

const doAvgBytewise = (as, bs) => as.map(a => Math.floor((a + bs[i]) / 2))
export const avgBytewise = (as, bs) => new BitArray(new Uint8Array(doAvgBytewise(as.buffer, bs.buffer)))

const doPaethBytewise = (as, bs, cs) => as.map((a, i) => {
    const b = bs[i]
    const c = cs[i]
    const p = a + b - c // initial estimate
    const pa = Math.abs(p - a) // distances to a, b, c
    const pb = Math.abs(p - b)
    const pc = Math.abs(p - c)
    // return nearest of a,b,c,
    // breaking ties in order a,b,c.
    if (pa <= pb && pa <= pc) return a
    else if (pb <= pc) return b
    else return c
})
export const paethBytewise = (as, bs, cs) => new BitArray(new Uint8Array(doPaethBytewise(as.buffer, bs.buffer, cs.buffer)))

const raise = message => { throw new Error(message) }

export const bitArrayToInts = (as, intSize = 8) => toList(
    intSize === 16 ? [...Array(as.buffer.length / 2)].map((_, i) => (as.buffer[i * 2] << 8) + as.buffer[i * 2 + 1]) :
    intSize === 8 ? [...as.buffer] :
    intSize === 4 ? [...as.buffer].flatMap(x => [x >> 4, x & 15]) :
    intSize === 2 ? [...as.buffer].flatMap(x => [x >> 6, x >> 4 & 3, x >> 2 & 3, x & 3]) :
    intSize === 1 ? [...as.buffer].flatMap(x => [x >> 7, x >> 6 & 1, x >> 5 & 1, x >> 4 & 1, x >> 3 & 1, x >> 2 & 1, x >> 1 & 1, x & 1]) :
    raise("Invalid int size")
)
