-- | This module provides a declarative DSL in which the user can specify the
-- different rules used to run the compilers.
--
-- The convention is to just list all items in the 'RulesM' monad, routes and
-- compilation rules.
--
-- A typical usage example would be:
--
-- > main = hakyll $ do
-- >     route   "posts/*" (setExtension "html")
-- >     compile "posts/*" someCompiler
--
{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings #-}
module Hakyll.Core.Rules
    ( RulesM
    , Rules
    , compile
    , create
    , route
    , metaCompile
    , metaCompileWith
    ) where

import Control.Applicative ((<$>))
import Control.Monad.Writer (tell)
import Control.Monad.Reader (ask)
import Control.Arrow (second, (>>>), arr, (>>^))
import Control.Monad.State (get, put)
import Data.Monoid (mempty)

import Data.Typeable (Typeable)
import Data.Binary (Binary)

import Hakyll.Core.ResourceProvider
import Hakyll.Core.Identifier
import Hakyll.Core.Identifier.Pattern
import Hakyll.Core.Compiler.Internal
import Hakyll.Core.Routes
import Hakyll.Core.CompiledItem
import Hakyll.Core.Writable
import Hakyll.Core.Rules.Internal
import Hakyll.Core.Util.Arrow

-- | Add a route
--
tellRoute :: Routes -> Rules
tellRoute route' = RulesM $ tell $ RuleSet route' mempty

-- | Add a number of compilers
--
tellCompilers :: (Binary a, Typeable a, Writable a)
             => [(Identifier, Compiler () a)]
             -> Rules
tellCompilers compilers = RulesM $ tell $ RuleSet mempty $
    map (second boxCompiler) compilers
  where
    boxCompiler = (>>> arr compiledItem >>> arr CompileRule)

-- | Add a compilation rule to the rules.
--
-- This instructs all resources matching the given pattern to be compiled using
-- the given compiler. When no resources match the given pattern, nothing will
-- happen. In this case, you might want to have a look at 'create'.
--
compile :: (Binary a, Typeable a, Writable a)
        => Pattern -> Compiler Resource a -> Rules
compile pattern compiler = RulesM $ do
    identifiers <- matches pattern . resourceList <$> ask
    unRulesM $ tellCompilers $ zip identifiers $ repeat $
        constA Resource >>> compiler

-- | Add a compilation rule
--
-- This sets a compiler for the given identifier. No resource is needed, since
-- we are creating the item from scratch.
--
create :: (Binary a, Typeable a, Writable a)
       => Identifier -> Compiler () a -> Rules
create identifier compiler = tellCompilers [(identifier, compiler)]

-- | Add a route.
--
-- This adds a route for all items matching the given pattern.
--
route :: Pattern -> Routes -> Rules
route pattern route' = tellRoute $ ifMatch pattern route'

-- | Apart from regular compilers, one is also able to specify metacompilers.
-- Metacompilers are a special class of compilers: they are compilers which
-- produce other compilers.
--
-- And indeed, we can see that the first argument to 'metaCompile' is a
-- 'Compiler' which produces a list of ('Identifier', 'Compiler') pairs. The
-- idea is simple: 'metaCompile' produces a list of compilers, and the
-- corresponding identifiers.
--
-- For simple hakyll systems, it is no need for this construction. More
-- formally, it is only needed when the content of one or more items determines
-- which items must be rendered.
--
metaCompile :: (Binary a, Typeable a, Writable a)
            => Compiler () [(Identifier, Compiler () a)]   
            -- ^ Compiler generating the other compilers
            -> Rules
            -- ^ Resulting rules
metaCompile compiler = RulesM $ do
    -- Create an identifier from the state
    state <- get
    let index = rulesMetaCompilerIndex state
        id' = fromCaptureString "Hakyll.Core.Rules.metaCompile/*" (show index)

    -- Update the state with a new identifier
    put $ state {rulesMetaCompilerIndex = index + 1}

    -- Fallback to 'metaCompileWith' with now known identifier
    unRulesM $ metaCompileWith id' compiler

-- | Version of 'metaCompile' that allows you to specify a custom identifier for
-- the metacompiler.
--
metaCompileWith :: (Binary a, Typeable a, Writable a)
                => Identifier
                -- ^ Identifier for this compiler
                -> Compiler () [(Identifier, Compiler () a)]   
                -- ^ Compiler generating the other compilers
                -> Rules
                -- ^ Resulting rules
metaCompileWith identifier compiler = RulesM $ tell $ RuleSet mempty
    [(identifier, compiler >>> arr makeRule )]
  where
    makeRule = MetaCompileRule . map (second box)
    box = (>>> fromDependency identifier >>^ CompileRule . compiledItem)
