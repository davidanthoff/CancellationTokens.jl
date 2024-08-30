@testitem "Base.sleep - do not cancel" begin
    src = CancellationTokenSource()
    sleep(0.1, get_token(src))
end

@testitem "Base.sleep - cancel" begin
    src = CancellationTokenSource()
    @async begin
        sleep(0.1)
        cancel(src)
    end
    @test_throws OperationCanceledException sleep(20.0, get_token(src))
end
