import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const logic = vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../shared/quickshell/desk/CalendarLogic.js', import.meta.url), 'utf8').replace(/^\.pragma library\s*/, ''), logic);
const date = (y, m, d) => new Date(y, m - 1, d, 12);
const filled = cells => cells.filter(cell => cell.day);
for (const firstDay of [0, 1, 6]) {
    for (const [year, month, count] of [[2024,2,29], [2025,2,28], [2026,11,30], [2027,1,31], [2100,2,28], [2000,2,29]]) {
        const cells = logic.cells(date(year,month,1), date(year,month,15), firstDay);
        assert.equal(cells.length, 42);
        assert.equal(filled(cells).length, count);
        assert.equal(cells.findIndex(cell => cell.day === 1), (date(year,month,1).getDay()-firstDay+7)%7);
        assert.equal(cells.filter(cell => cell.past).length, 14);
        assert.equal(cells.filter(cell => cell.today).length, 1);
        assert.ok(cells.find(cell => cell.day === 15).today);
        assert.ok(cells.filter(cell => !cell.day).every(cell => !cell.today && !cell.past));
    }
}
assert.ok(filled(logic.cells(date(2026,10,1),date(2026,11,5),1)).every(cell=>cell.past&&!cell.today));
assert.ok(filled(logic.cells(date(2026,12,1),date(2026,11,5),1)).every(cell=>!cell.past&&!cell.today));
const next = logic.monthAt(date(2026,12,31),1);
assert.equal(next.getFullYear(),2027);assert.equal(next.getMonth(),0);assert.equal(next.getDate(),1);
const prev = logic.monthAt(date(2027,1,31),-1);
assert.equal(prev.getFullYear(),2026);assert.equal(prev.getMonth(),11);
// Calendar days remain consecutive over the US DST changes.
for (const month of [3,11]) {
    const days = filled(logic.cells(date(2026,month,1),date(2026,month,10),0));
    assert.deepEqual(Array.from(days,cell=>cell.day),Array.from({length:days.length},(_,i)=>i+1));
}
console.log('calendar dates, locale week starts, leap years, year boundaries and past-day marks: passed');
