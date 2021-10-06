{-
-- Maybe is already defined by Haskell Prelude,
-- but I'll include it here for completeness

data Maybe a = Nothing
             | Just a

instance Monad Maybe where
    -- bind together operations
    Just x >>= k  =  k x
    Nothing >>= _ =  Nothing

    -- inject value
    return x      =  Just x

    -- then
    Just _ >> k   =  k
    Nothing >> _  =  Nothing

    fail _        =  Nothing
-}

animalFriends :: [(String, String)]
animalFriends = [ ("Pony", "Lion")
                , ("Lion", "Manticore")
                , ("Unicorn", "Lepricon")
                ]

-- Explicitly chaining Maybes to find ponys friends friends friend
animalFriendLookup :: [(String, String)] -> Maybe String
animalFriendLookup animalMap =
  case lookup "Pony" animalMap of
       Nothing -> Nothing
       Just ponyFriend ->
         case lookup ponyFriend animalMap of
              Nothing -> Nothing
              Just ponyFriendFriend ->
                case lookup ponyFriendFriend animalMap of
                     Nothing -> Nothing
                     Just friend -> Just friend

-- Use Bind to chain lookups
monadicAnimalFriendLookup :: [(String, String)] -> Maybe String
monadicAnimalFriendLookup animalMap =
      lookup "Pony" animalMap
  >>= (\ponyFriend -> lookup ponyFriend animalMap
  >>= (\ponyFriendFriend -> lookup ponyFriendFriend animalMap
  >>= (\friend -> Just friend)))

-- Use Do-Block sugar magic
sugaryAnimalFriendLookup :: [(String, String)] -> Maybe String
sugaryAnimalFriendLookup animalMap = do
  ponyFriend <- lookup "Pony" animalMap
  ponyFriendFriend <- lookup ponyFriend animalMap
  friend <- lookup ponyFriendFriend animalMap
  return friend

-- Use Bind to chain lookups
monadicAnimalFriendLookup' :: [(String, String)] -> Maybe String
monadicAnimalFriendLookup' animalMap =
      lookup "Pony" animalMap
  >>= flip lookup animalMap
  >>= flip lookup animalMap
