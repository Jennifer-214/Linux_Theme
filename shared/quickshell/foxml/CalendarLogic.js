.pragma library

// Local noon keeps calendar arithmetic away from DST transitions at midnight.
function monthAt(date, offset) {
    return new Date(date.getFullYear(), date.getMonth() + offset, 1, 12);
}

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function cells(month, today, firstDay) {
    var year = month.getFullYear(), m = month.getMonth();
    var offset = (new Date(year, m, 1, 12).getDay() - firstDay + 7) % 7;
    var count = new Date(year, m + 1, 0, 12).getDate();
    var result = [];
    var now = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 12).getTime();
    for (var i = 0; i < 42; ++i) {
        var day = i - offset + 1, date = new Date(year, m, day, 12);
        var present = day > 0 && day <= count;
        result.push({day: present ? day : 0, today: present && sameDay(date, today),
                     past: present && date.getTime() < now});
    }
    return result;
}
