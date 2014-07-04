\documentclass{article}
\begin{document}
\section{Imports}
\begin{code}
{-# LANGUAGE BangPatterns #-}
{-
(c) Jyotirmoy Bhattacharya, 2014
jyotirmoy@jyotirmoy.net

Licensed under GPL v3
-}

module Main where

import Control.Monad
import Data.Array.Repa as R
import Data.Array.Repa.Algorithms.Matrix
import Prelude as P
import Text.Printf
import Data.List.Stream as S
import qualified Data.Vector.Unboxed as V

ninfnty::Double
ninfnty=read "-Infinity"
\end{code}
\section{Parameters}

\begin{code}

aalpha::Double
aalpha = (1.0/3.0)     --Elasticity of output w.r.t. capital

bbeta::Double
bbeta  = 0.95    -- Discount factor

-- Productivity values
vProductivity::Array U DIM1 Double
vProductivity = fromListUnboxed (ix1 $ P.length l) l
  where
    l = [0.9792, 0.9896, 1.0000, 1.0106, 1.0212]

-- Transition matrix
mTransition::Array U DIM2 Double
mTransition   = fromListUnboxed (ix2 5 5) (
  [0.9727, 0.0273, 0.0000, 0.0000, 0.0000,
   0.0041, 0.9806, 0.0153, 0.0000, 0.0000,
   0.0000, 0.0082, 0.9837, 0.0082, 0.0000,
   0.0000, 0.0000, 0.0153, 0.9806, 0.0041,
   0.0000, 0.0000, 0.0000, 0.0273, 0.9727])

\end{code}

\section{Steady State}

\begin{code}

capitalSteadyState::Double
capitalSteadyState = (aalpha*bbeta)**(1/(1-aalpha))

outputSteadyState::Double
outputSteadyState = capitalSteadyState**aalpha

consumptionSteadyState::Double
consumptionSteadyState = outputSteadyState-capitalSteadyState               
nGridCapital::Int
nGridCapital = 17800
\end{code}

\section{Working variables}

We generate the grid of capital.

\begin{code}
vGridCapital::Array U DIM1 Double
vGridCapital = fromUnboxed (ix1 nGridCapital) vec
               where
                 start = 0.5*capitalSteadyState
                 step = capitalSteadyState/(fromIntegral nGridCapital)
                 vec = V.enumFromStepN start step nGridCapital

nGridProductivity::Int
(Z:.nGridProductivity) = extent vProductivity
\end{code}
 
We pre-build output for each point in the grid.

\begin{code}
mOutput::Array U DIM2 Double
mOutput = computeS $ (R.zipWith f xK xP)
  where
    f !k !p = (k**aalpha) * p
    xK = extend (Z:.All:.nGridProductivity) vGridCapital
    xP = extend (Z:.nGridCapital:.All) vProductivity
\end{code}

\section{Maximization}

Compute the value function given the level of this period's 
capital, productivity and next period's capital. We make use
of the expected value function \texttt{evf} that is passed to us.

\begin{code}
{-# INLINE compute_vf #-}
compute_vf::Array U DIM2 Double->Int->Int->Int->Double
compute_vf !evf !cap !prod !nxt = v
  where
    y = mOutput ! (ix2 cap prod)
    k' = vGridCapital ! (ix1 nxt)
    c = y - k'
    ev = evf ! (ix2 nxt prod)
    v = (1-bbeta)*(log c)+bbeta*ev 
\end{code}
 
A helper function to compute the peak of a single-peaked function.
It is passed the function itself, and the points in its domain to
consider.

\begin{code}
{-# INLINE findPeak #-}
findPeak::(Int->Double)->[Int]->Int
findPeak _ [] = error "Empty argument to findPeak"
findPeak keyfn (x:xs) = go (keyfn x) x xs
  where
    go _ !l [] = l
    go !v !l (y:ys) =  
      let ky = keyfn y in
        case ky<=v of
          True -> l
          False -> go ky y ys
\end{code}


Find the best policy for for a cerain stock of capital
and productivity. We are passed a lower bound for
the domain to search in the parameter \texttt{start}.

\begin{code}
policy::Int->Int->Int->Array U DIM2 Double->Int
policy !cap !prod !start !evf = 
  findPeak fn [start..(nGridCapital-1)]
  where
    fn nxt = compute_vf evf cap prod nxt 
\end{code}

Find the best policies for each level of capital for a 
given level of productivity. We make use of the 
monotonicity of the policy function to begin our search
for each level of capital at the point where the search
for the previous level of capital succeeded.

\begin{code}
policies::Array U DIM2 Double->Int->[Int]
policies !evf !prod = S.unfoldr next (0,0)
  where
    next (!cap,!start) = if cap == nGridCapital then
                            Nothing
                         else Just (p,(cap+1,p))
      where p = policy cap prod start evf
\end{code}
 
\section{Value function iteration}
\begin{code}
data DPState = DPState {vf::Array U DIM2 Double,
                        pf::Array U DIM2 Double}
               
iterDP::DPState->DPState
iterDP s = DPState {vf = nvf,pf =npf}
  where
    evf = mmultS (vf s) (transpose2S mTransition)
    ps = [0..(nGridProductivity-1)]
    bestpol = V.concat $ P.map (V.fromList.policies evf) ps
    nk' = R.transpose $ fromUnboxed (Z:.nGridProductivity:.nGridCapital) bestpol
    npf = computeS (fromFunction (Z:.nGridCapital:.nGridProductivity)
                    (\(Z:.i:.j) -> vGridCapital ! ix1 (nk' ! ix2 i j)))
    nvf = computeS (fromFunction (Z:.nGridCapital:.nGridProductivity)
                    (\(Z:.i:.j)->compute_vf evf i j (nk' ! (ix2 i j))))
          
supdiff::Array U DIM2 Double->Array U DIM2 Double->Double
supdiff v1 v2 = foldAllS max ninfnty $ R.map abs (v1 -^ v2)
 
\end{code}

\section{Drivers}
\begin{code}
initstate::DPState
initstate = DPState {vf=z,pf=z}
  where
    z = computeS $ fromFunction (Z:.nGridCapital:.nGridProductivity) (const 0.0)
    
printvf::Array U DIM2 Double->IO()
printvf v = mapM_ go [(i,j)|i<-[0,100..(nGridCapital-1)],
                       j<-[0..(nGridProductivity-1)]]
  where
    go (i,j) = (printf "%g\t%g\t%g\n" 
                (vGridCapital ! (ix1 i))
                (vProductivity ! (ix1 j))
                (v ! (Z:.i:.j)))
               

tolerance::Double
tolerance = 1e-7

maxIter::Int
maxIter=1000


main::IO()
main = do
  go 1 initstate
  where
    go::Int->DPState->IO()
    go !count !s = 
      let ns = iterDP s
          d = supdiff (vf s) (vf ns) in
      if (d <tolerance) || (count>maxIter) then do
        printf "My check = %.6g\n" (pf ns ! ix2 999 2)
      else do
        when (count `mod` 10==0) $ printf "Iteration = %d, Sup Diff = %.6g\n" count d
        go (count+1) ns
\end{code}
\end{document}