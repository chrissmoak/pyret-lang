#lang pyret

fun mklist():
  for list.map(i from list.range(0, 10000)):
    i * 7
  end
check:
  checkers.check-true("simple", mklist() == mklist())
end

