#set page(width: 15cm, height: auto, margin: 1cm)
#set text(size: 11pt)

= Bubble Sort Algorithm

Bubble sort is a simple sorting algorithm that repeatedly steps through the list, compares adjacent elements and swaps them if they are in the wrong order. The pass through the list is repeated until the list is sorted.

== Visual Representation
#block(
  fill: luma(240),
  inset: 10pt,
  radius: 4pt,
  [
    Initial State: `[5, 1, 4, 2, 8]` \
    Step 1: `[1, 5, 4, 2, 8]` (5 > 1, swap) \
    Step 2: `[1, 4, 5, 2, 8]` (5 > 4, swap) \
    Step 3: `[1, 4, 2, 5, 8]` (5 > 2, swap) \
    Step 4: `[1, 4, 2, 5, 8]` (5 < 8, no swap)
  ]
)

== Complexity
- *Worst Case:* $O(n^2)$
- *Average Case:* $O(n^2)$
- *Best Case:* $O(n)$
- *Space Complexity:* $O(1)$

== Code (Python)
```python
def bubble_sort(arr):
    n = len(arr)
    for i in range(n):
        for j in range(0, n-i-1):
            if arr[j] > arr[j+1]:
                arr[j], arr[j+1] = arr[j+1], arr[j]
```
