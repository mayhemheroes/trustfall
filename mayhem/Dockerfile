# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest as builder

## Add source code to the build stage.
ADD . /src
WORKDIR /src

RUN echo building instrumented harnesses && \
    bash -c "pushd trustfall_core/fuzz && cargo +nightly -Z sparse-registry fuzz build && popd" && \
    mv trustfall_core/fuzz/target/x86_64-unknown-linux-gnu/release/frontend /frontend && \
    mv trustfall_core/fuzz/target/x86_64-unknown-linux-gnu/release/frontend_numbers /frontend_numbers && \
    echo done

RUN echo building non-instrumented harnesses && \
    export RUSTFLAGS="--cfg fuzzing -Clink-dead-code -Cdebug-assertions -C codegen-units=1" && \
    bash -c "pushd trustfall_core/fuzz && cargo +nightly -Z sparse-registry build --release && popd" && \
    mv trustfall_core/fuzz/target/release/frontend /frontend_no_inst && \
    mv trustfall_core/fuzz/target/release/frontend_numbers /frontend_numbers_no_inst && \
    echo done

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /frontend /frontend_no_inst /
COPY --from=builder /frontend_numbers /frontend_numbers_no_inst /
