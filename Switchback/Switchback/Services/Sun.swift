import Foundation

/// Sunrise and sunset worked out on the phone (no network), with the standard almanac formula.
enum Sun {
    /// Today's sunrise and sunset at the place, or nil during polar day or night.
    static func times(on date: Date, at c: Coord) -> (sunrise: Date, sunset: Date)? {
        guard let rise = event(on: date, at: c, rising: true), let set = event(on: date, at: c, rising: false) else { return nil }
        return (sunrise: rise, sunset: set)
    }

    private static func event(on date: Date, at c: Coord, rising: Bool) -> Date? {
        let rad = Double.pi / 180
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let parts = local.dateComponents([.year, .month, .day], from: date)
        guard let n = local.ordinality(of: .day, in: .year, for: date) else { return nil }
        let lngHour = c.lon / 15
        let t = Double(n) + ((rising ? 6 : 18) - lngHour) / 24
        let m = 0.9856 * t - 3.289
        var l = m + 1.916 * sin(m * rad) + 0.020 * sin(2 * m * rad) + 282.634
        l = l.truncatingRemainder(dividingBy: 360)
        if l < 0 { l += 360 }
        var ra = atan(0.91764 * tan(l * rad)) / rad
        ra = ra.truncatingRemainder(dividingBy: 360)
        if ra < 0 { ra += 360 }
        ra += floor(l / 90) * 90 - floor(ra / 90) * 90
        ra /= 15
        let sinDec = 0.39782 * sin(l * rad)
        let cosDec = cos(asin(sinDec))
        let cosH = (cos(90.833 * rad) - sinDec * sin(c.lat * rad)) / (cosDec * cos(c.lat * rad))
        guard cosH >= -1, cosH <= 1 else { return nil }
        var h = rising ? 360 - acos(cosH) / rad : acos(cosH) / rad
        h /= 15
        let localMean = h + ra - 0.06571 * t - 6.622
        var ut = (localMean - lngHour).truncatingRemainder(dividingBy: 24)
        if ut < 0 { ut += 24 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let midnight = utc.date(from: parts) else { return nil }
        var result = midnight.addingTimeInterval(ut * 3600)
        // keep the result within the local day asked for (west of Greenwich, evening UTC times fall on the next day)
        guard let noon = local.date(bySettingHour: 12, minute: 0, second: 0, of: date) else { return result }
        while result.timeIntervalSince(noon) > 12 * 3600 { result.addTimeInterval(-86400) }
        while noon.timeIntervalSince(result) > 12 * 3600 { result.addTimeInterval(86400) }
        return result
    }
}
