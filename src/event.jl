@static if VERSION < v"1.2"
    # Julia < 1.2 lacks Threads.Condition; provide a minimal condition
    # variable that supports lock/unlock/wait/notify with an external lock.
    mutable struct WaitCondition
        _lock::ReentrantLock
        _q::Vector{Task}
        WaitCondition(lock::ReentrantLock) = new(lock, Task[])
    end

    Base.lock(c::WaitCondition) = lock(c._lock)
    Base.unlock(c::WaitCondition) = unlock(c._lock)

    function Base.wait(c::WaitCondition)
        ct = current_task()
        push!(c._q, ct)
        unlock(c._lock)
        try
            wait()
        catch
            lock(c._lock)
            filter!(x -> x !== ct, c._q)
            rethrow()
        end
        lock(c._lock)
        return nothing
    end

    function Base.notify(c::WaitCondition; all::Bool=true)
        if all
            for t in c._q
                schedule(t)
            end
            empty!(c._q)
        elseif !isempty(c._q)
            schedule(popfirst!(c._q))
        end
        return nothing
    end
else
    const WaitCondition = Threads.Condition
end
