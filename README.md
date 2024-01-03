# AAML final project

## Run instruction

- For building gateware
```
make prog USEVIVADO=1 TTY=/dev/ttyUSB0 EXTRA_LITEX_ARGS="--cpu-variant=perf+cfu"
```

- For building binary
```
sudo make load BUILD_JOBS=4 TTY=/dev/ttyUSB1
```

- Note

The include path in cfu.v is absoulte path. Relative path doesn't play well on my system. If you want to build plase remember to change it!