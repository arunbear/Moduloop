requires 'Class::Method::Modifiers', '2.12';
requires 'Config::Tiny', '2.23';
requires 'List::MoreUtils',  '0.33';
requires 'Module::Runtime', '0.014';
requires 'Package::Stash', '0.36';
requires 'Params::Validate', '1.10';
requires 'Sub::Name',      '0.09';
requires 'Readonly';

on test => sub {
    requires 'Test::Lib',  '0.002';
    requires 'Test::Most', '0.34';
    requires 'Test::Output', '1.03';
};
