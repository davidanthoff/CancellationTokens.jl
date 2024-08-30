@testitem "Cancel before wait" begin

    src = CancellationTokenSource()
    cancel(src)
    wait(get_token(src))
end

@testitem "Async cancel" begin
    src = CancellationTokenSource()
    @async begin
        sleep(0.1)
        cancel(src)
    end
    wait(get_token(src))
end

@testitem "Source with timeout" begin
    src = CancellationTokenSource(0.1)
    wait(get_token(src))
end
