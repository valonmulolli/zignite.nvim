#set page(width: 15cm, height: auto, margin: 1cm)
#set text(size: 11pt)

= Binary Search Algorithm

Binary search is an efficient algorithm for finding an item from a sorted list of items. It works by repeatedly dividing in half the portion of the list that could contain the item, until you've narrowed down the possible locations to just one.

== Visual Representation
Target: *7* \
List: `[1, 3, 4, 5, 7, 8, 9]`

#table(
  columns: (auto, auto, auto, auto),
  [*Step*], [*Low*], [*High*], [*Mid*],
  [1], [0], [6], [3 (Val: 5)],
  [2], [4], [6], [5 (Val: 8)],
  [3], [4], [4], [4 (Val: 7)],
)

*Result:* Found at index 4

== Complexity
- *Time Complexity:* $O(log n)$
- *Space Complexity:* $O(1)$

== Code (C++)
```cpp
int binarySearch(int arr[], int l, int r, int x) {
    while (l <= r) {
        int m = l + (r - l) / 2;
        if (arr[m] == x) return m;
        if (arr[m] < x) l = m + 1;
        else r = m - 1;
    }
    return -1;
}
```
