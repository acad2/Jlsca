# This file is part of Jlsca, license is GPLv3, see https://www.gnu.org/licenses/gpl-3.0.en.html
#
# Author: Cees-Bart Breunesse

using ProgressMeter

import Base.length, Base.getindex, Base.setindex!
import Base.reset
import Base.start, Base.done, Base.next, Base.endof


export Trace,readTraces,addSamplePass,popSamplePass,addDataPass,popDataPass,hasPostProcessor,reset,getCounter,setPostProcessor
export start,done,next,endof,setindex!

abstract type Trace end

export Pass

abstract type Pass end

type SimpleFunctionPass <: Pass 
  fn::Function
end

pass(a::SimpleFunctionPass, x::AbstractArray{T,1}, idx::Int) where {T} = a.fn(x) 

# overloading these to implement an iterator
start(trs::Trace) = 1
done(trs::Trace, idx) = pipe(trs) ? false : (idx > length(trs))
next(trs::Trace, idx) = (trs[idx], idx+1)
endof(trs::Trace) = length(trs)

function getData(trs::Trace, idx)
  data = readData(trs, idx)

  # run all the passes over the data
  for fn in trs.dataPasses
    data = fn(data)
    if length(data) == 0
      break
    end
  end

  return data
end

function getSamples(trs::Trace, idx)
  samples = readSamples(trs, idx)

  # run all the passes over the trace
  for p in trs.passes
   samples = pass(p, samples, idx)
   if length(samples) == 0
     break
   end
  end

  return samples
end

# gets a single trace from a list of traces, runs all the data and sample passes, adds it through the post processor, and returns the result
function getindex(trs::Trace, idx)
  data = getData(trs, idx)
  local samples

  if length(data) > 0
    samples = getSamples(trs, idx)
  end

  if length(data) == 0 || length(samples) == 0
    samples = Vector{trs.sampleType}(0)
    data = Vector{eltype(data)}(0)
  end

  return (data, samples)
end

function setindex!(trs::Trace, t::Tuple{Vector,Vector}, idx::Int)
  (data, samples) = t
  writeData(trs, idx, data)
  writeSamples(trs, idx, samples)
end

# add a sample pass (just a Function over a Vector{FLoat64}) to the list of passes for this trace set
addSamplePass(trs::Trace, f::Function, prprnd=false) = addSamplePass(trs, SimpleFunctionPass(f), prprnd)

# add a sample pass (just a Function over a Vector{FLoat64}) to the list of passes for this trace set
function addSamplePass(trs::Trace, p::Pass, prprnd=false)
  if prprnd == true
    trs.passes = vcat(p, trs.passes)
  else
    trs.passes = vcat(trs.passes, p)
  end
  return nothing
end

# removes a sample pass
function popSamplePass(trs::Trace, fromStart=false)
  if fromStart
    trs.passes = trs.passes[2:end]
  else
    trs.passes = trs.passes[1:end-1]
  end
  return nothing
end

# add a data pass (just a Function over a Vector{x} where x is the type of the trace set)
function addDataPass(trs::Trace, f::Function, prprnd=false)
  if prprnd == true
    trs.dataPasses = vcat(f, trs.dataPasses)
  else
    trs.dataPasses = vcat(trs.dataPasses, f)
  end
  return nothing
end

# removes a data pass
function popDataPass(trs::Trace, fromStart=false)
  if fromStart
    trs.dataPasses = trs.dataPasses[2:end]
  else
    trs.dataPasses = trs.dataPasses[1:end-1]
  end
  return nothing
end

# removes the data processor and sets the number of traces it fed into the post processor to 0.
function reset(trs::Trace)
  if trs.postProcInstance != Union
    reset(trs.postProcInstance)
  end
  trs.tracesReturned = 0
end

# returns the number of traces it fed into the post processor
function getCounter(trs::Trace)
  return trs.tracesReturned
end

function setPostProcessor(trs::Trace, p::PostProcessor)
  trs.postProcInstance = p
end

# returns true when a post processor is set to this trace set
function hasPostProcessor(trs::Trace)
  return trs.postProcInstance != Union
end

function readTraces(trs::Trace, range::Range)
  if isa(trs, DistributedTrace) || hasPostProcessor(trs)
    return readAndPostProcessTraces(trs, range)
  else
    return readNoPostProcessTraces(trs, range)
  end
end

export TraceKind

@enum TraceKind NonzeroData=1 NonzeroSamples=2 NonzeroDataSamples=3

export getFirstValid

"""
Returns the first valid trace from a trace set, where validity is (by default) non-zero data and non-zero samples. See `TraceKind`.

# Examples
```
(data,samples,idx) = getFirstValid(trs,NonzeroDataSamples)
# same as:
(data,samples,idx) = getFirstValid(trs)

```

"""
function getFirstValid(trs::Trace, kind::TraceKind=NonzeroDataSamples)
  for t in 1:length(trs)
    (data,samples) = trs[t]
    if kind == NonzeroDataSamples && (length(data) == 0 || length(samples) == 0)
      continue
    elseif kind == NonzeroSamples && length(samples) == 0
      continue
    elseif kind == NonzeroData && length(data) == 0
      continue
    end
    return (data,samples,t)
  end
  throw(ErrorException("no trace of $kind found .."))
end

# read traces without conditional averaging (but with all the data and sample passes), creates huge matrices, use with care
function readNoPostProcessTraces(trs::Trace, range::Range)
  numberOfTraces = length(trs)
  readCount = 0
  allSamples = nothing
  allData = nothing
  eof = false
  local data, samples, dataLength, sampleLength

  traceLength = length(range)

  if !pipe(trs)
    progress = Progress(traceLength-1, 1, "Processing traces .. ")
  end

  for idx in range
    (data, samples) = trs[idx]

    if length(data) == 0 || length(samples) == 0
      continue
    end

    if allSamples == nothing || allData == nothing
        # first time, so allocate
        sampleLength = length(samples)
        dataLength = length(data)
        if isa(samples, BitVector)
          # bit vectors are 8 times better than Vectors of bools since bit vectors are packed
          allSamples = BitVector(sampleLength * traceLength)
        else
          allSamples = Vector{eltype(samples)}(sampleLength * traceLength)
        end
        allData = Vector{eltype(data)}(dataLength * traceLength)
    end

    allSamples[readCount*sampleLength+1:readCount*sampleLength+sampleLength] = samples
    allData[readCount*dataLength+1:readCount*dataLength+dataLength] = data

    # valid trace, bump read counter
    readCount += 1

    if !pipe(trs)
      update!(progress, idx)
    end
  end

  trs.tracesReturned += readCount

  # resize & reshape that shit depending on the readCount
  resize!(allData, (dataLength*readCount))
  resize!(allSamples, (sampleLength*readCount))

  allData = reshape(allData, (dataLength, readCount))'
  allSamples = reshape(allSamples, (sampleLength, readCount))'

  return ((allData, allSamples), eof)
end

function updateProgress(x::Int)
  progress = Main.getProgress()
  if progress != nothing
    update!(progress, progress.counter + x)
  end
end

function readAndPostProcessTraces(trs2::Trace, range::Range)

  traceLength = length(range)

  if isa(trs2, DistributedTrace)
    worksplit = @fetch Main.trs.postProcInstance.worksplit
  else
    worksplit = trs2.postProcInstance.worksplit
  end

  if !pipe(trs2)
    progress = Progress(traceLength, 1, @sprintf("Processing traces %s.. ", range))
  else
    progress = nothing
  end

  @everywhere getProgress()=$progress

  if isa(trs2, DistributedTrace)
    @sync begin
      for w in workers()
        @async begin
          @fetchfrom w begin
            add(Main.trs.postProcInstance, Main.trs, range, updateProgress)
          end
        end
      end
    end
  else
    add(trs2.postProcInstance, trs2, range, updateProgress)
  end

  if progress != nothing
    finish!(progress)
  end

  if isa(trs2, DistributedTrace)
    worker1copy = @fetchfrom workers()[1] Main.trs.postProcInstance
    ret = get(worker1copy)
  else
    ret = get(trs2.postProcInstance)
  end

  return (ret, true)

end
